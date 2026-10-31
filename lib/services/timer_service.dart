import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/hearth_notification.dart';
import '../utils/logger.dart';
import 'android_sounds.dart';
import 'notification_service.dart';
import 'voice_satellite_bridge.dart';

/// A single countdown timer managed by [TimerService].
///
/// A local timer counts down from when it was set. A voice timer belongs to
/// Home Assistant, which reports its time left on every change; between
/// reports it counts down from the last one, and it is done only when Home
/// Assistant says it finished. Either way the remaining time comes from the
/// wall clock, so it stays accurate even if the UI misses ticks.
/// The [id] is used to identify timers for dismissal.
class HubTimer {
  final int id;

  /// Home Assistant's id for a voice timer; null for a timer set on Hearth.
  final String? remoteId;

  String _name = '';
  Duration _total;
  Duration _left;
  DateTime _leftAt = DateTime.now();
  bool _paused = false;
  bool _finished = false;
  bool _dismissed = false;

  HubTimer({
    required this.id,
    required Duration totalDuration,
  })  : remoteId = null,
        _total = totalDuration,
        _left = totalDuration;

  HubTimer._remote(this.id, VoiceTimerEvent event)
      : remoteId = event.id,
        _total = event.total,
        _left = event.left {
    _apply(event);
  }

  void _apply(VoiceTimerEvent event) {
    _name = event.name;
    _total = event.total;
    _left = event.left;
    _leftAt = DateTime.now();
    _paused = !event.active;
  }

  bool get isRemote => remoteId != null;

  /// The name the timer was set with by voice; empty otherwise.
  String get name => _name;

  /// A voice timer paused from Home Assistant.
  bool get isPaused => _paused;

  Duration get totalDuration => _total;

  Duration get remaining {
    if (_finished) return Duration.zero;
    if (_paused) return _left;
    final left = _left - DateTime.now().difference(_leftAt);
    return left.isNegative ? Duration.zero : left;
  }

  /// How long a running voice timer has sat at zero without Home Assistant
  /// saying it finished.
  Duration get _overdue => DateTime.now().difference(_leftAt) - _left;

  double get progress {
    if (totalDuration.inMilliseconds == 0) return 0;
    return 1.0 - (remaining.inMilliseconds / totalDuration.inMilliseconds);
  }

  bool get isDone => isRemote ? _finished : remaining == Duration.zero;
  bool get isDismissed => _dismissed;

  /// Format remaining time as "H:MM:SS" or "MM:SS".
  String get remainingLabel {
    final r = remaining;
    final h = r.inHours;
    final m = r.inMinutes.remainder(60);
    final s = r.inSeconds.remainder(60);
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

/// Global timer service that survives navigation.
///
/// Timers live here instead of in the TimerScreen widget, so they keep
/// counting even when the user navigates back to Home or the display
/// goes ambient. When a timer fires, [firedTimers] is non-empty and
/// the HubShell shows a full-screen alert overlay.
class TimerService extends ChangeNotifier {
  final List<HubTimer> _timers = [];
  Timer? _ticker;
  int _nextId = 0;

  /// When set, a fired timer is surfaced as an alert-priority sticky card in
  /// the notification deck (source=timer). Optional so direct-constructed
  /// instances in tests behave as before (looping beep, no cards).
  NotificationService? _notificationService;

  /// Wire the notification store so fired timers become deck cards. Called by
  /// [timerServiceProvider]; the fired-timer looping beep stays here.
  void attachNotificationService(NotificationService service) {
    _notificationService = service;
  }

  /// The voice satellite's ring, on Android. When set, a fired local timer
  /// rings through it, and the beep is the fallback for when it cannot.
  Future<bool> Function()? _startRing;
  Future<void> Function()? _stopRing;

  /// The satellite is ringing, for a voice timer or a local one.
  bool _ringing = false;

  void attachRing({
    required Future<bool> Function() start,
    required Future<void> Function() stop,
  }) {
    _startRing = start;
    _stopRing = stop;
  }

  /// Stable deck-card id for a timer, so re-ingest can't stack duplicates and
  /// dismissal maps back to the timer.
  static String _cardId(int timerId) => 'timer-$timerId';

  /// All active (non-dismissed) timers.
  List<HubTimer> get timers => _timers.where((t) => !t.isDismissed).toList();

  /// Timers that have finished but haven't been dismissed yet.
  /// The HubShell watches this to show the alert overlay.
  List<HubTimer> get firedTimers =>
      _timers.where((t) => t.isDone && !t.isDismissed).toList();

  /// Whether any timers are actively counting down.
  bool get hasActiveTimers => _timers.any((t) => !t.isDone && !t.isDismissed);

  /// Summary for the home screen button, e.g., "1 timer · 3:42"
  String get statusLabel {
    final active = timers.where((t) => !t.isDone).toList();
    if (active.isEmpty) return '';
    if (active.length == 1) return active.first.remainingLabel;
    return '${active.length} timers';
  }

  void startTimer(Duration duration) {
    _timers.add(HubTimer(id: _nextId++, totalDuration: duration));
    _ensureTicking();
    notifyListeners();
  }

  /// A voice timer changed in Home Assistant. The satellite rings a finished
  /// one by itself, so this raises the alert without ringing.
  void applyRemoteEvent(VoiceTimerEvent event) {
    final match = _timers.where((t) => t.remoteId == event.id);
    var timer = match.isEmpty ? null : match.first;
    if (event.type == 'cancelled') {
      if (timer != null) _remove(timer);
      return;
    }
    if (timer == null) {
      timer = HubTimer._remote(_nextId++, event);
      _timers.add(timer);
    } else {
      timer._apply(event);
    }
    if (event.type == 'finished' && !timer._finished) {
      timer._finished = true;
      _ringing = true;
      _alreadyFired.add(timer.id);
      _ingestTimerCard(timer);
    }
    _ensureTicking();
    notifyListeners();
  }

  /// The satellite's ring ended by the stop word or a wake word, or the
  /// service went away. Every fired timer was ringing through it.
  void onRingStopped() {
    _ringing = false;
    if (firedTimers.isNotEmpty) dismissAllFired();
  }

  /// The satellite stopped, and with it the voice timers' updates.
  void clearRemote() {
    for (final t in _timers.where((t) => t.isRemote).toList()) {
      _remove(t);
    }
  }

  void _remove(HubTimer timer) {
    timer._dismissed = true;
    _alreadyFired.remove(timer.id);
    _timers.remove(timer);
    if (firedTimers.isEmpty) _stopAlarmSound();
    if (_timers.isEmpty) _stopTicking();
    notifyListeners();
    _notificationService?.dismiss(_cardId(timer.id));
  }

  void dismissTimer(int id) {
    final match = _timers.where((t) => t.id == id);
    if (match.isEmpty) {
      // Timer already gone (e.g. re-entered from the card's onDismiss) — just
      // make sure its card is cleared. dismiss() is idempotent, so this ends
      // the loop rather than recursing.
      _notificationService?.dismiss(_cardId(id));
      return;
    }
    final timer = match.first;
    if (timer.isRemote && !timer.isDone) {
      // Home Assistant owns it, and the device cannot cancel a timer.
      Log.i('Timer', 'Voice timer ${timer.remoteId} is cancelled from Home Assistant, not here');
      return;
    }
    _remove(timer);
  }

  /// Dismiss all fired timers at once (e.g., an HA `timer/cancel` with no id).
  void dismissAllFired() {
    final fired = firedTimers;
    for (final t in fired) {
      t._dismissed = true;
      _alreadyFired.remove(t.id);
    }
    _timers.removeWhere((t) => t.isDismissed);
    _stopAlarmSound();
    if (_timers.isEmpty) _stopTicking();
    notifyListeners();
    for (final t in fired) {
      _notificationService?.dismiss(_cardId(t.id));
    }
  }

  /// Start a periodic tick that drives UI updates.
  /// 200ms is fast enough for smooth countdown display without
  /// burning CPU on a kiosk that runs 24/7.
  void _ensureTicking() {
    _ticker ??= Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _onTick(),
    );
  }

  /// Set of timer IDs that have already triggered their alarm.
  /// Prevents the alarm from firing repeatedly on every tick.
  final Set<int> _alreadyFired = {};

  /// How long a voice timer may sit at zero waiting for Home Assistant's
  /// `finished` before it is taken as lost, e.g. across a disconnect.
  static const _remoteGrace = Duration(seconds: 60);

  void _onTick() {
    for (final timer in _timers.where((t) => t.isRemote).toList()) {
      if (!timer.isDone && !timer.isPaused && timer._overdue > _remoteGrace) {
        Log.w('Timer', 'Voice timer ${timer.remoteId} never finished; dropping');
        _remove(timer);
      }
    }
    // Check for newly fired timers: play the alarm sound and surface a card.
    for (final timer in _timers) {
      if (timer.isDone && !timer.isDismissed && !_alreadyFired.contains(timer.id)) {
        _alreadyFired.add(timer.id);
        _playAlarmSound();
        _ingestTimerCard(timer);
      }
    }
    notifyListeners();
  }

  /// Surface a fired timer as an alert-priority sticky card. The card's
  /// `onDismiss` maps back to [dismissTimer] so swiping/closing the card also
  /// dismisses the timer (and stops the looping beep once the last one clears).
  void _ingestTimerCard(HubTimer timer) {
    _notificationService?.ingest(HearthNotification(
      id: _cardId(timer.id),
      source: NotificationSource.timer,
      sourceLabel: defaultSourceLabel(NotificationSource.timer),
      priority: NotificationPriority.alert,
      title: "Time's up",
      body: timer.name.isNotEmpty
          ? timer.name
          : '${_formatDuration(timer.totalDuration)} timer',
      sticky: true,
      timestamp: DateTime.now(),
      onDismiss: () => dismissTimer(timer.id),
    ));
  }

  /// Format a whole-timer duration as "H:MM:SS" or "M:SS" for the card body.
  static String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Process? _alarmProcess;
  bool _alarmLooping = false;

  /// Ring for a fired local timer: through the satellite when there is one,
  /// else the beep.
  void _playAlarmSound() {
    final start = _startRing;
    if (start == null) return _playBeep();
    if (_ringing) return;
    _ringing = true;
    start().then((ok) {
      if (!ok) {
        _ringing = false;
        _playBeep();
      } else if (!_ringing) {
        // Dismissed before the service answered.
        _stopRing?.call();
      }
    });
  }

  /// Play a looping beep when a timer fires. Uses GStreamer's audiotestsrc
  /// to generate a sine tone (no asset bundle dependency) and routes through
  /// autoaudiosink, which picks pipewiresink/alsasink based on what's
  /// available, or the native player on Android. Loops until [_stopAlarmSound] is called by dismissTimer
  /// or dismissAllFired.
  void _playBeep() {
    if (!Platform.isLinux && !playsSoundsOnAndroid) {
      Log.i('Timer', 'Would play alarm tone (non-Linux platform)');
      return;
    }
    if (_alarmLooping) return; // already beeping for an earlier timer
    _alarmLooping = true;
    _alarmLoop();
  }

  Future<void> _alarmLoop() async {
    // 880 Hz sine, ~0.46s tone via num-buffers=20 (20 * 1024 / 44100), then
    // ~0.4s of silence in Dart-land before the next subprocess. Result is
    // a "beep ... beep ... beep" pattern at ~1.2 Hz.
    while (_alarmLooping) {
      try {
        if (playsSoundsOnAndroid) {
          await AndroidSounds.playTone(
              880, const Duration(milliseconds: 464), 0.5);
        } else {
          _alarmProcess = await Process.start('gst-launch-1.0', [
            'audiotestsrc', 'wave=sine', 'freq=880', 'num-buffers=20',
            '!', 'audioconvert',
            '!', 'volume', 'volume=0.5',
            '!', 'autoaudiosink',
          ]);
          await _alarmProcess!.exitCode;
        }
        if (!_alarmLooping) break;
        await Future.delayed(const Duration(milliseconds: 400));
      } catch (e) {
        Log.e('Timer', 'Alarm playback failed: $e');
        break;
      }
    }
    _alarmProcess = null;
  }

  void _stopAlarmSound() {
    if (_ringing) {
      _ringing = false;
      _stopRing?.call();
    }
    _alarmLooping = false;
    _alarmProcess?.kill();
    _alarmProcess = null;
  }

  void _stopTicking() {
    _ticker?.cancel();
    _ticker = null;
  }

  @override
  void dispose() {
    _stopAlarmSound();
    _stopTicking();
    super.dispose();
  }
}

/// Wires [timers] to the in-app voice satellite: Home Assistant's voice
/// timers in, the ring out. Returns the teardown.
VoidCallback linkVoiceSatelliteTimers(
    TimerService timers, VoiceSatelliteBridge bridge) {
  timers.attachRing(start: bridge.startTimerRing, stop: bridge.stopTimerRing);
  final subs = <StreamSubscription<Object?>>[
    bridge.timerStream.listen(timers.applyRemoteEvent),
    bridge.ringStoppedStream.listen((_) => timers.onRingStopped()),
    bridge.statusStream.listen((s) {
      if (!s.running) timers.clearRemote();
    }),
  ];
  return () {
    for (final sub in subs) {
      sub.cancel();
    }
  };
}

final timerServiceProvider = ChangeNotifierProvider<TimerService>((ref) {
  final service = TimerService();
  // Route fired timers into the notification deck as alert-priority cards.
  service.attachNotificationService(ref.read(notificationServiceProvider));
  if (voiceSatelliteSupported) {
    ref.onDispose(linkVoiceSatelliteTimers(
        service, ref.read(voiceSatelliteBridgeProvider)));
  }
  return service;
});
