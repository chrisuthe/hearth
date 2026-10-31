import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/ha_entity.dart';
import '../../services/home_assistant_service.dart';
import '../../utils/logger.dart';

/// Where a snooze's ramp starts: the dark purple on screen, 30% on the lights.
const double kSunriseSnoozeLevel = 0.3;

/// The lights a sunrise can offer, by name. On/off lights are left out, because
/// the first step of the ramp would turn them on at full.
List<HaEntity> sunriseLightChoices(Iterable<HaEntity> entities) => entities
    .where((e) => e.domain == 'light' && e.isDimmable)
    .toList()
  ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

/// Draws the dawn colours and ramps Home Assistant lights towards an alarm.
///
/// [AlarmService] decides which alarm a sunrise belongs to and when it ends;
/// this holds the ramp it's told to [run] and follows the clock along it.
class SunriseController extends ChangeNotifier {
  static final _keyframes = <double, Color>{
    0.00: const Color(0xFF000000),
    0.15: const Color(0xFF0A1028),
    0.30: const Color(0xFF2A1040),
    0.50: const Color(0xFF4A2010),
    0.70: const Color(0xFFC05820),
    0.85: const Color(0xFFE8A030),
    1.00: const Color(0xFFFFD890),
  };

  static const _lightInterval = Duration(seconds: 30);
  static const _warmestKelvin = 2200;
  static const _coolestKelvin = 4000;

  /// How much of the photo the finished tint covers.
  static const _maxOverlayAlpha = 0.7;

  /// The progress by which the tint has fully faded in.
  static const _overlayFadeEnd = 0.3;

  final DateTime Function() _clock;
  final HomeAssistantService Function()? _ha;

  SunriseController({
    DateTime Function()? clock,
    HomeAssistantService Function()? ha,
  })  : _clock = clock ?? DateTime.now,
        _ha = ha;

  double _progress = 0.0;
  Timer? _ticker;
  bool _active = false;
  String? _alarmId;
  DateTime? _start;
  DateTime? _end;
  double _from = 0.0;
  List<String> _lightEntities = [];
  DateTime? _lightsSentAt;

  double get progress => _progress;
  bool get active => _active;

  Color get currentColor {
    final entries = _keyframes.entries.toList();
    for (int i = 0; i < entries.length - 1; i++) {
      if (_progress >= entries[i].key && _progress <= entries[i + 1].key) {
        final t = (_progress - entries[i].key) /
            (entries[i + 1].key - entries[i].key);
        return Color.lerp(entries[i].value, entries[i + 1].value, t)!;
      }
    }
    return entries.last.value;
  }

  /// How opaque the tint over the photos is: the photos fade down to the dawn
  /// rather than cutting to dark when the sunrise starts.
  double get overlayAlpha =>
      _maxOverlayAlpha * (_progress / _overlayFadeEnd).clamp(0.0, 1.0);

  /// Black or white, whichever reads better on [background].
  ///
  /// 0.179 is the luminance where the two contrast equally, so one of them
  /// always clears 4.5:1.
  static Color inkOn(Color background) =>
      background.computeLuminance() > 0.179 ? Colors.black : Colors.white;

  /// Runs the ramp from [start] to [end], climbing from level [from].
  ///
  /// Safe to call on every check: the same ramp carries on undisturbed, and so
  /// does a finished one when the alarm it was for is still at full. A ramp
  /// that started in the past joins partway along.
  void run({
    required String alarmId,
    required DateTime start,
    required DateTime end,
    double from = 0.0,
    List<String> lights = const [],
  }) {
    final sameAlarm = _active && _alarmId == alarmId;
    if (sameAlarm && _start == start && _end == end && _from == from) {
      _lightEntities = lights;
      return;
    }
    if (sameAlarm && _progress >= 1.0 && !end.isAfter(_clock())) {
      _lightEntities = lights;
      return;
    }

    _alarmId = alarmId;
    _start = start;
    _end = end;
    _from = from;
    _lightEntities = lights;
    _lightsSentAt = null;
    _active = true;
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    Log.i('Sunrise', 'Ramp for alarm $alarmId, $start to $end');
    _tick();
  }

  void _tick() {
    final now = _clock();
    final total = _end!.difference(_start!).inMilliseconds;
    final t = total <= 0
        ? 1.0
        : (now.difference(_start!).inMilliseconds / total).clamp(0.0, 1.0);
    _progress = _from + (1.0 - _from) * t;

    final sentAt = _lightsSentAt;
    if (t >= 1.0 ||
        sentAt == null ||
        now.difference(sentAt) >= _lightInterval) {
      _lightsSentAt = now;
      _sendLights(t);
    }
    if (t >= 1.0) {
      // Full: nothing changes until the alarm is dealt with.
      _ticker?.cancel();
      _ticker = null;
    }
    notifyListeners();
  }

  void _sendLights(double t) {
    final ha = _ha;
    if (ha == null || _lightEntities.isEmpty) return;

    // Quadratic ease-in: slow start, accelerating.
    final eased = t * t;
    // At least 1: Home Assistant takes brightness 0 to mean "turn off".
    final brightness =
        (255 * (_from + (1.0 - _from) * eased)).round().clamp(1, 255);
    final kelvin =
        (_warmestKelvin + (_coolestKelvin - _warmestKelvin) * eased).round();

    final service = ha();
    for (final entityId in _lightEntities) {
      service.callService(
        domain: 'light',
        service: 'turn_on',
        entityId: entityId,
        data: {
          'brightness': brightness,
          'color_temp_kelvin': kelvin,
        },
      );
    }
    Log.d('Sunrise',
        'Lights: brightness=$brightness, kelvin=$kelvin, progress=${_progress.toStringAsFixed(2)}');
  }

  /// Ends the sunrise. Lights are left as they are: whoever stopped it is awake.
  void stop() {
    if (!_active) return;
    _ticker?.cancel();
    _ticker = null;
    _active = false;
    _progress = 0.0;
    _alarmId = null;
    _start = null;
    _end = null;
    _lightsSentAt = null;
    Log.i('Sunrise', 'Stopped');
    notifyListeners();
  }

  /// Test-only: run one check without waiting for the ticker.
  @visibleForTesting
  void tickForTest() {
    if (_ticker != null) _tick();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}

final sunriseControllerProvider =
    ChangeNotifierProvider<SunriseController>((ref) {
  return SunriseController(ha: () => ref.read(homeAssistantServiceProvider));
});
