import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../utils/logger.dart';
import 'alarm_audio.dart';
import 'alarm_models.dart';

// dart:io and path_provider compile to stubs on web — guarded by kIsWeb at runtime.
import 'dart:io' if (dart.library.html) 'dart:io';
import 'package:path_provider/path_provider.dart';

/// How long a tone rings before stopping, so an alarm can't sound all day in
/// an empty house. The alarm stays on screen until someone deals with it.
const Duration kAlarmToneLimit = Duration(minutes: 30);

/// Persistence and scheduling service for alarms.
///
/// Follows the same ChangeNotifier pattern as [TimerService]. Alarms are
/// persisted to `alarms.json` in the app support directory. A short periodic
/// ticker checks whether any enabled alarm is due, and the chosen tone rings
/// from when an alarm fires until it's snoozed, dismissed or hits [_toneLimit].
class AlarmService extends ChangeNotifier {
  /// Where `alarms.json` lives. Defaults to the app support directory;
  /// injectable so tests can point it at a temp directory.
  final Future<String> Function() _directory;

  final DateTime Function() _clock;
  final AlarmAudioPlayer _audio;
  final Duration _toneLimit;

  AlarmService({
    Future<String> Function()? directory,
    DateTime Function()? clock,
    AlarmAudioPlayer? audio,
    Duration toneLimit = kAlarmToneLimit,
  })  : _directory = directory ?? _supportDirectory,
        _clock = clock ?? DateTime.now,
        _audio = audio ?? AlarmAudioPlayer(),
        _toneLimit = toneLimit;

  static Future<String> _supportDirectory() async =>
      (await getApplicationSupportDirectory()).path;

  List<Alarm> _alarms = [];
  Alarm? _firedAlarm;
  Timer? _ticker;
  Timer? _toneTimer;

  /// Whether the alarm on screen has rung for its whole [_toneLimit].
  bool _toneExpired = false;

  /// When each snoozed alarm rings again.
  final Map<String, DateTime> _snoozes = {};

  /// Alarms that came due while another was on screen, oldest first.
  final List<String> _waiting = [];

  /// How late a check may land and still ring the alarm. Past this, the moment
  /// has gone (the kiosk was off, say) and the alarm waits for its next time.
  static const _lateWindow = Duration(seconds: 60);

  /// The occurrence of each alarm already rung or deliberately skipped, so one
  /// occurrence rings once however many checks land in its window.
  final Map<String, DateTime> _handled = {};

  // ---------------------------------------------------------------------------
  // Getters
  // ---------------------------------------------------------------------------

  /// All alarms, sorted by time.
  List<Alarm> get alarms => List.unmodifiable(_alarms);

  /// The alarm currently firing (awaiting snooze/dismiss), or null.
  Alarm? get firedAlarm => _firedAlarm;

  /// When the next snooze expires, or null if nothing is snoozed.
  DateTime? get snoozedUntil {
    DateTime? earliest;
    for (final until in _snoozes.values) {
      if (earliest == null || until.isBefore(earliest)) earliest = until;
    }
    return earliest;
  }

  /// The next alarm to fire: returns (alarm, fireTime) for the soonest
  /// enabled alarm, or null if none are scheduled.
  (Alarm, DateTime)? get nextAlarm {
    final now = _clock();
    (Alarm, DateTime)? best;
    for (final alarm in _alarms) {
      final next = alarm.nextFireTime(now);
      if (next != null && (best == null || next.isBefore(best.$2))) {
        best = (alarm, next);
      }
    }
    return best;
  }

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  /// Load alarms from disk. Called once at app startup.
  Future<void> load() async {
    if (kIsWeb) return;
    try {
      final file = File('${await _directory()}/alarms.json');
      if (await file.exists()) {
        final raw = await file.readAsString();
        final list = jsonDecode(raw) as List<dynamic>;
        _alarms = list
            .map((e) => Alarm.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      Log.e('AlarmService', 'Failed to load alarms.json: $e');
      _alarms = [];
    }
    _ensureTicking();
    notifyListeners();
  }

  Future<void> _save() async {
    if (kIsWeb) return;
    try {
      final file = File('${await _directory()}/alarms.json');
      await file.writeAsString(jsonEncode(_alarms.map((a) => a.toJson()).toList()));
    } catch (e) {
      Log.e('AlarmService', 'Failed to save alarms.json: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // CRUD
  // ---------------------------------------------------------------------------

  void addAlarm(Alarm alarm) {
    _alarms.add(alarm);
    _skipIfJustPassed(alarm);
    _save();
    _ensureTicking();
    notifyListeners();
  }

  void updateAlarm(Alarm alarm) {
    final idx = _alarms.indexWhere((a) => a.id == alarm.id);
    if (idx >= 0) {
      _alarms[idx] = alarm;
      _skipIfJustPassed(alarm);
      if (!alarm.enabled) {
        _stopRinging(alarm.id);
      } else if (_firedAlarm?.id == alarm.id) {
        _updateRinging(alarm);
      }
      _save();
      notifyListeners();
    }
  }

  /// Replaces every alarm, as a restore does, and waits for the save.
  Future<void> replaceAll(List<Alarm> alarms) async {
    _alarms = [...alarms];
    _handled.clear();
    _alarms.forEach(_skipIfJustPassed);
    _firedAlarm = null;
    _snoozes.clear();
    _waiting.clear();
    _stopTone();
    await _save();
    if (_alarms.isEmpty) {
      _stopTicking();
    } else {
      _ensureTicking();
    }
    notifyListeners();
  }

  void deleteAlarm(String id) {
    _alarms.removeWhere((a) => a.id == id);
    _handled.remove(id);
    _stopRinging(id);
    _save();
    if (_alarms.isEmpty) _stopTicking();
    notifyListeners();
  }

  void toggleEnabled(String id) {
    final idx = _alarms.indexWhere((a) => a.id == id);
    if (idx >= 0) {
      _alarms[idx] = _alarms[idx].copyWith(enabled: !_alarms[idx].enabled);
      _handled.remove(id);
      if (_alarms[idx].enabled) {
        _skipIfJustPassed(_alarms[idx]);
      } else {
        _stopRinging(id);
      }
      _save();
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // Ticker
  // ---------------------------------------------------------------------------

  /// Start the periodic ticker that checks alarm fire times.
  void _ensureTicking() {
    _ticker ??= Timer.periodic(
      const Duration(seconds: 5),
      (_) => _onTick(),
    );
  }

  void _stopTicking() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _onTick() {
    final now = _clock();

    for (final entry in _snoozes.entries.toList()) {
      if (!now.isBefore(entry.value)) {
        _snoozes.remove(entry.key);
        _enqueue(entry.key);
      }
    }
    for (final alarm in _alarms) {
      if (!alarm.enabled) continue;
      final occurrence = _dueOccurrence(alarm, now);
      if (occurrence == null || _handled[alarm.id] == occurrence) continue;
      _handled[alarm.id] = occurrence;
      _enqueue(alarm.id);
    }

    if (_waiting.isEmpty) return;
    if (_firedAlarm != null) {
      if (!_toneExpired) return; // Still ringing, the next one waits its turn.
      // Nobody came. An alarm left on screen mustn't swallow the next one.
      dismiss();
    }
    final id = _waiting.removeAt(0);
    final alarm = _alarms.where((a) => a.id == id && a.enabled).firstOrNull;
    if (alarm != null) _fireAlarm(alarm);
  }

  void _enqueue(String id) {
    if (!_waiting.contains(id)) _waiting.add(id);
  }

  /// The time [alarm] was due within [_lateWindow] before [now], if any.
  DateTime? _dueOccurrence(Alarm alarm, DateTime now) {
    final occurrence = alarm.nextFireTime(now.subtract(_lateWindow));
    if (occurrence == null || occurrence.isAfter(now)) return null;
    return occurrence;
  }

  /// An alarm set for a time that has only just passed means its next
  /// occurrence, not one that rings the moment it's saved.
  void _skipIfJustPassed(Alarm alarm) {
    final occurrence = _dueOccurrence(alarm, _clock());
    if (occurrence != null) _handled[alarm.id] = occurrence;
  }

  void _fireAlarm(Alarm alarm) {
    _firedAlarm = alarm;
    _snoozes.remove(alarm.id);
    _startTone(alarm);
    notifyListeners();
  }

  void _startTone(Alarm alarm) {
    _stopTone();
    if (alarm.soundType != 'none') {
      _audio.play(alarm.soundId, volume: alarm.volume);
    }
    _toneTimer = Timer(_toneLimit, () {
      _toneTimer = null;
      _toneExpired = true;
      _audio.stop();
    });
  }

  void _stopTone() {
    _toneTimer?.cancel();
    _toneTimer = null;
    _toneExpired = false;
    _audio.stop();
  }

  /// Keeps the ringing alarm current, restarting the tone only if it changed.
  void _updateRinging(Alarm alarm) {
    final previous = _firedAlarm!;
    _firedAlarm = alarm;
    if (alarm.soundType != previous.soundType ||
        alarm.soundId != previous.soundId ||
        alarm.volume != previous.volume) {
      _startTone(alarm);
    }
  }

  /// Ends everything [id] has in progress, when it's deleted or turned off.
  void _stopRinging(String id) {
    _snoozes.remove(id);
    _waiting.remove(id);
    if (_firedAlarm?.id == id) {
      _firedAlarm = null;
      _stopTone();
    }
  }

  /// Test-only: simulate an alarm firing without waiting for the ticker.
  @visibleForTesting
  void fireAlarmForTest(Alarm alarm) => _fireAlarm(alarm);

  /// Test-only: run one check without waiting for the ticker.
  @visibleForTesting
  void tickForTest() => _onTick();

  // ---------------------------------------------------------------------------
  // Snooze / Dismiss
  // ---------------------------------------------------------------------------

  /// Snooze the currently firing alarm.
  void snooze() {
    if (_firedAlarm == null) return;
    _snoozes[_firedAlarm!.id] = _clock().add(
      Duration(minutes: _firedAlarm!.snoozeDuration),
    );
    _firedAlarm = null;
    _stopTone();
    notifyListeners();
  }

  /// Dismiss the currently firing alarm. One-time alarms are auto-disabled.
  void dismiss() {
    if (_firedAlarm == null) return;
    final alarm = _firedAlarm!;
    _firedAlarm = null;
    _stopTone();

    // Auto-disable one-time alarms after dismissal.
    if (alarm.oneTime || alarm.days.isEmpty) {
      final idx = _alarms.indexWhere((a) => a.id == alarm.id);
      if (idx >= 0) {
        _alarms[idx] = _alarms[idx].copyWith(enabled: false);
        _save();
      }
    }

    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void dispose() {
    _stopTicking();
    _stopTone();
    super.dispose();
  }
}

final alarmServiceProvider = ChangeNotifierProvider<AlarmService>((ref) {
  return AlarmService();
});
