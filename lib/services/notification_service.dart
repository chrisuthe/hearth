import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/hub_config.dart';
import '../models/hearth_notification.dart';
import '../utils/logger.dart';
import 'display_mode_service.dart';

/// How long a transient (non-sticky) card lives before auto-dismissing.
const Duration kTransientNotificationLifetime = Duration(seconds: 6);

/// Global notification store — the single list feeding the bottom-deck surface.
///
/// Shape mirrors `TimerService`: a [ChangeNotifier] that owns the active list
/// and drives the UI via `notifyListeners`. Every source (Frigate, Unifi, HA,
/// push, and fired timers) normalizes into a [HearthNotification] and lands
/// here via [ingest].
///
/// Side effects are injected so unit tests exercise ingest/dismiss/expiry with
/// no audio subprocess: [playChime] defaults to a GStreamer one-shot on Linux
/// (a log on other platforms), and [isChimeSuppressed] defaults to never
/// suppressing (the provider wires it to night mode).
class NotificationService extends ChangeNotifier {
  NotificationService({
    Future<void> Function(HearthNotification)? playChime,
    bool Function()? isChimeSuppressed,
    Duration transientLifetime = kTransientNotificationLifetime,
  })  : _playChime = playChime ?? _defaultPlayChime,
        _isChimeSuppressed = isChimeSuppressed ?? (() => false),
        _transientLifetime = transientLifetime;

  final List<HearthNotification> _notifications = [];
  final Map<String, Timer> _autoDismissTimers = {};

  /// Tags the user dismissed while their automation may still be re-sending
  /// them. Updates for these are ignored until a `clear` arrives or the tag's
  /// `timeout` passes with no update.
  final Map<String, Timer> _dismissedTags = {};
  final Future<void> Function(HearthNotification) _playChime;
  final bool Function() _isChimeSuppressed;
  final Duration _transientLifetime;

  /// Active notifications, oldest first → newest last (the deck stacks newest
  /// at the bottom, closest to the hand).
  List<HearthNotification> get notifications =>
      List.unmodifiable(_notifications);

  bool get hasActive => _notifications.isNotEmpty;

  /// Add a notification: append, play its chime (unless muted, suppressed by
  /// night mode, or timer-sourced — `TimerService` owns the looping fired-timer
  /// beep), and arm a 6s auto-dismiss for transient cards.
  ///
  /// A tagged card updates in place with no chime, and an update for a tag the
  /// user dismissed is dropped without notifying, so it can't wake the screen.
  void ingest(HearthNotification notification) {
    final tag = notification.tag;
    if (tag != null && _dismissedTags.containsKey(tag)) {
      _rememberDismissedTag(tag, notification.timeout);
      return;
    }

    // Replace any existing card with the same id (e.g. a timer re-ingested)
    // so a stable id can't stack duplicates.
    final existing = _notifications.indexWhere((n) => n.id == notification.id);
    if (existing >= 0 && tag != null) {
      _autoDismissTimers.remove(notification.id)?.cancel();
      _notifications[existing] = notification.updating(_notifications[existing]);
      notifyListeners();
      _armAutoDismiss(notification);
      return;
    }
    if (existing >= 0) {
      _autoDismissTimers.remove(notification.id)?.cancel();
      _notifications.removeAt(existing);
    }

    _notifications.add(notification);
    notifyListeners();

    final chimeAllowed = !notification.muted &&
        !_isChimeSuppressed() &&
        notification.source != NotificationSource.timer;
    if (chimeAllowed) {
      _playChime(notification);
    }

    _armAutoDismiss(notification);
  }

  /// Normalize an inbound MQTT or HTTP payload and act on it: `clear: true`
  /// with a `tag` closes that card, anything else surfaces a card. Returns the
  /// affected card's id, or null when the payload is invalid.
  String? ingestPayload(Map<String, dynamic> json) {
    if (json['clear'] == true) {
      final tag = HearthNotification.tagFromPayload(json);
      if (tag == null) return null;
      clear(tag);
      return HearthNotification.idForTag(tag);
    }
    final notification = HearthNotification.fromIngest(json);
    if (notification == null) return null;
    ingest(notification);
    return notification.id;
  }

  /// Close the card for [tag] and forget any dismissal of it. Idempotent.
  void clear(String tag) {
    _dismissedTags.remove(tag)?.cancel();
    _remove(HearthNotification.idForTag(tag));
  }

  /// Remove one notification by id, as the user dismissing it. Idempotent — a
  /// no-op if it's already gone, which keeps the timer-card ↔ `TimerService`
  /// dismissal loop from recursing.
  ///
  /// A tagged card with a `timeout` is remembered, so the automation's next
  /// heartbeat can't bring it back. Without a `timeout` nothing would ever end
  /// that memory, so the tag stays free to show again.
  void dismiss(String id) {
    final index = _notifications.indexWhere((n) => n.id == id);
    if (index < 0) return;
    final card = _notifications[index];
    final tag = card.tag;
    if (tag != null && card.timeout != null) {
      _rememberDismissedTag(tag, card.timeout);
    }
    _remove(id);
  }

  void _remove(String id) {
    final index = _notifications.indexWhere((n) => n.id == id);
    if (index < 0) return;
    final removed = _notifications.removeAt(index);
    _autoDismissTimers.remove(id)?.cancel();
    notifyListeners();
    removed.onDismiss?.call();
  }

  void _armAutoDismiss(HearthNotification notification) {
    final lifetime = notification.timeout ??
        (notification.sticky ? null : _transientLifetime);
    if (lifetime == null) return;
    _autoDismissTimers[notification.id] =
        Timer(lifetime, () => _remove(notification.id));
  }

  void _rememberDismissedTag(String tag, Duration? timeout) {
    _dismissedTags.remove(tag)?.cancel();
    if (timeout == null) return;
    _dismissedTags[tag] = Timer(timeout, () => _dismissedTags.remove(tag));
  }

  /// Remove every active notification and cancel all timers.
  void clearAll() {
    if (_notifications.isEmpty) return;
    final removed = List<HearthNotification>.from(_notifications);
    _notifications.clear();
    for (final timer in _autoDismissTimers.values) {
      timer.cancel();
    }
    _autoDismissTimers.clear();
    notifyListeners();
    for (final n in removed) {
      n.onDismiss?.call();
    }
  }

  @override
  void dispose() {
    for (final timer in _autoDismissTimers.values) {
      timer.cancel();
    }
    _autoDismissTimers.clear();
    for (final timer in _dismissedTags.values) {
      timer.cancel();
    }
    _dismissedTags.clear();
    super.dispose();
  }

  /// One-shot arrival chime. Alert = an urgent triple beep; info = a single
  /// soft ping. Generated with GStreamer's `audiotestsrc` (no bundled asset),
  /// mirroring `TimerService`'s alarm tone. A log-only no-op off Linux.
  static Future<void> _defaultPlayChime(HearthNotification n) async {
    if (!Platform.isLinux) {
      debugPrint('[NotificationService] chime: ${n.chimeLabel} (${n.priority.name})');
      return;
    }
    try {
      if (n.priority == NotificationPriority.alert) {
        // Ember Alert: urgent triple beep (880 / 1174 / 880 Hz).
        for (final freq in [880, 1174, 880]) {
          await _tone(freq, buffers: 7, volume: 0.35);
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
      } else {
        // Soft Ping: a single gentle sine.
        await _tone(740, buffers: 22, volume: 0.16);
      }
    } catch (e) {
      Log.e('Notification', 'Chime playback failed: $e');
    }
  }

  /// Play one short sine tone and wait for it to finish. `buffers` sets the
  /// length (each ~1024/44100 ≈ 23ms), matching `TimerService`'s approach.
  static Future<void> _tone(int freq,
      {required int buffers, required double volume}) async {
    final process = await Process.start('gst-launch-1.0', [
      'audiotestsrc', 'wave=sine', 'freq=$freq', 'num-buffers=$buffers',
      '!', 'audioconvert',
      '!', 'volume', 'volume=$volume',
      '!', 'autoaudiosink',
    ]);
    await process.exitCode;
  }
}

/// Single, stable notification store. Not recreated by Riverpod (nothing is
/// `watch`ed here) so its list survives unrelated config edits. The chime is
/// suppressed while the display is in night mode.
final notificationServiceProvider =
    ChangeNotifierProvider<NotificationService>((ref) {
  return NotificationService(
    isChimeSuppressed: () {
      if (kIsWeb) return false;
      final config = ref.read(hubConfigProvider);
      final mode =
          ref.read(displayModeServiceProvider).resolveMode(config: config);
      return mode == DisplayMode.night;
    },
  );
});
