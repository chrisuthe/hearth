import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config/hub_config.dart';
import '../../../models/hearth_notification.dart';
import '../../../services/audio_coordinator.dart';
import '../../../services/notification_service.dart';
import '../camera_feed_overlay.dart';
import 'doorbell_call_session.dart';
import 'doorbell_platform.dart';
import 'go2rtc_signaling.dart';
import 'rtc_client.dart';

/// How long a call view stays open when Talk is never used and the ring
/// carried no `timeout`.
const kDoorbellQuietTimeout = Duration(minutes: 3);

/// How long a ring that arrived with Hearth in the background waits for
/// Hearth to come forward.
const kRingSummonWindow = Duration(seconds: 15);

/// How long a notice shows in the call view. The toast layer sits below the
/// call view, so notices are drawn by the view itself.
const kDoorbellNoticeDuration = Duration(seconds: 4);

const kTalkUnavailable = 'Talk unavailable';
const kMicPermissionNeeded = 'Microphone permission needed';

/// Builds the session for one call; the controller passes its loss handlers.
typedef DoorbellSessionFactory = DoorbellCallSession Function(
  String camera, {
  void Function()? onLost,
  void Function()? onTalkLost,
});

/// The open doorbell call view.
@immutable
class DoorbellCall {
  final String camera;
  final String? tag;
  final DateTime openedAt;
  final DoorbellCallSession session;

  /// The doorbell's video and audio are playing.
  final bool connected;

  /// Talk has been on at some point, which changes the view's lifetime.
  final bool talkUsed;
  final bool talkOn;

  /// A short message shown in the view, such as [kTalkUnavailable].
  final String? notice;

  const DoorbellCall({
    required this.camera,
    required this.tag,
    required this.openedAt,
    required this.session,
    this.connected = false,
    this.talkUsed = false,
    this.talkOn = false,
    this.notice,
  });

  DoorbellCall copyWith({
    bool? connected,
    bool? talkUsed,
    bool? talkOn,
    String? Function()? notice,
  }) =>
      DoorbellCall(
        camera: camera,
        tag: tag,
        openedAt: openedAt,
        session: session,
        connected: connected ?? this.connected,
        talkUsed: talkUsed ?? this.talkUsed,
        talkOn: talkOn ?? this.talkOn,
        notice: notice != null ? notice() : this.notice,
      );
}

/// The lifetime rules of the doorbell call view (issue #315).
///
/// - A ring opens the view at once while Hearth is visible. Otherwise it
///   summons Hearth and waits [kRingSummonWindow] for it.
/// - Without Talk, the view closes after the ring's `timeout` (or
///   [kDoorbellQuietTimeout]), or on a `clear` for its tag. Once Talk has
///   been used, it closes [kCameraFeedMaxDuration] after it opened.
/// - A ring for another camera replaces the view unless Talk is on. A repeat
///   ring for the same camera leaves it alone.
/// - Hang up, or Hearth leaving the screen, closes it.
///
/// Every close disposes the session, which releases the satellite and
/// playback holds.
class DoorbellCallController extends StateNotifier<DoorbellCall?> {
  DoorbellCallController({
    required DoorbellSessionFactory createSession,
    required DoorbellPlatform platform,
    required bool Function() isForeground,
    required void Function() closeFeed,
    required void Function(String camera) fallbackToFeed,
    DateTime Function()? now,
  })  : _createSession = createSession,
        _platform = platform,
        _isForeground = isForeground,
        _closeFeed = closeFeed,
        _fallbackToFeed = fallbackToFeed,
        _now = now ?? DateTime.now,
        super(null);

  final DoorbellSessionFactory _createSession;
  final DoorbellPlatform _platform;
  final bool Function() _isForeground;
  final void Function() _closeFeed;
  final void Function(String camera) _fallbackToFeed;
  final DateTime Function() _now;

  Timer? _deadline;
  DateTime? _closeAt;
  Timer? _noticeTimer;
  HearthNotification? _pending;
  Timer? _pendingTimer;

  /// Completes when every closed session has released its hold. The native
  /// hold and the playback mute are single flags, so a new call must not
  /// take them before the old call's release lands.
  Future<void>? _released;

  void ring(HearthNotification ring) {
    if (ring.camera == null) return;
    if (!_isForeground()) {
      _pending = ring;
      _pendingTimer?.cancel();
      _pendingTimer = Timer(kRingSummonWindow, () => _pending = null);
      unawaited(_platform.summon(ring.title));
      return;
    }
    _open(ring);
  }

  void _open(HearthNotification ring) {
    final camera = ring.camera!;
    final current = state;
    if (current != null) {
      if (current.camera == camera || current.talkOn) return;
      _close();
    }
    _closeFeed();

    late final DoorbellCallSession session;
    session = _createSession(
      camera,
      onLost: () => _fallback(session),
      onTalkLost: () => _onTalkLost(session),
    );
    final openedAt = _now();
    state = DoorbellCall(
      camera: camera,
      tag: ring.tag,
      openedAt: openedAt,
      session: session,
    );
    // The ring's own timeout only: a picture card's 10-minute default is
    // for the card, not the call.
    _arm(openedAt.add(
        ring.timeoutGiven ? ring.timeout! : kDoorbellQuietTimeout));
    unawaited(_start(session));
  }

  Future<void> _start(DoorbellCallSession session) async {
    final released = _released;
    if (released != null) {
      await released;
      if (state?.session != session) return;
    }
    final ok = await session.start();
    if (state?.session != session) return;
    if (ok) {
      state = state!.copyWith(connected: true);
    } else {
      _fallback(session);
    }
  }

  /// WebRTC failed: close, and play today's listen-only feed instead.
  void _fallback(DoorbellCallSession session) {
    final call = state;
    if (call == null || call.session != session) return;
    _close();
    _fallbackToFeed(call.camera);
  }

  void _onTalkLost(DoorbellCallSession session) {
    if (state?.session != session) return;
    state = state!.copyWith(talkOn: false);
    _notify(kTalkUnavailable);
  }

  void clear(String tag) {
    final call = state;
    if (call != null && call.tag == tag && !call.talkUsed) _close();
  }

  Future<void> setTalk(bool on) async {
    final call = state;
    if (call == null) return;
    final result = await call.session.setTalk(on);
    final current = state;
    if (current == null || current.session != call.session) return;
    switch (result) {
      case TalkResult.on:
        // Talk never shortens the view, even past the 5-minute cap.
        final cap = current.openedAt.add(kCameraFeedMaxDuration);
        if (!current.talkUsed && cap.isAfter(_closeAt!)) _arm(cap);
        state = current.copyWith(talkOn: true, talkUsed: true);
      case TalkResult.off:
        state = current.copyWith(talkOn: false);
      case TalkResult.failed:
        state = current.copyWith(talkOn: false);
        _notify(kTalkUnavailable);
      case TalkResult.micDenied:
        state = current.copyWith(talkOn: false);
        _notify(kMicPermissionNeeded);
    }
  }

  void hangUp() => _close();

  void onLifecycle(AppLifecycleState lifecycle) {
    switch (lifecycle) {
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        _close();
      case AppLifecycleState.resumed:
        final pending = _pending;
        _pending = null;
        _pendingTimer?.cancel();
        if (pending != null) _open(pending);
      default:
    }
  }

  void _notify(String message) {
    state = state?.copyWith(notice: () => message);
    _noticeTimer?.cancel();
    _noticeTimer = Timer(kDoorbellNoticeDuration, () {
      if (state?.notice == message) {
        state = state!.copyWith(notice: () => null);
      }
    });
  }

  void _arm(DateTime closeAt) {
    _deadline?.cancel();
    _closeAt = closeAt;
    final left = closeAt.difference(_now());
    _deadline = Timer(left.isNegative ? Duration.zero : left, _close);
  }

  void _close() {
    _deadline?.cancel();
    _noticeTimer?.cancel();
    final call = state;
    if (call == null) return;
    state = null;
    final previous = _released;
    final release = call.session.dispose();
    _released = previous == null ? release : Future.wait([previous, release]);
  }

  @override
  void dispose() {
    _close();
    _pendingTimer?.cancel();
    super.dispose();
  }
}

/// The doorbell call view's state. Read at boot on Android so rings are
/// heard before any widget watches it.
final doorbellCallProvider =
    StateNotifierProvider<DoorbellCallController, DoorbellCall?>((ref) {
  final platform = ref.read(doorbellPlatformProvider);
  final controller = DoorbellCallController(
    createSession: (camera, {onLost, onTalkLost}) => DoorbellCallSession(
      signaling:
          go2rtcSignalingUri(ref.read(hubConfigProvider).frigateUrl, camera),
      rtc: ref.read(rtcClientProvider),
      platform: platform,
      muteHearthPlayback: ref.read(audioCoordinatorProvider).setCallActive,
      onLost: onLost,
      onTalkLost: onTalkLost,
    ),
    platform: platform,
    isForeground: () => switch (WidgetsBinding.instance.lifecycleState) {
      null || AppLifecycleState.resumed || AppLifecycleState.inactive => true,
      _ => false,
    },
    closeFeed: () => ref.read(cameraFeedProvider.notifier).close(),
    fallbackToFeed: (camera) => ref
        .read(cameraFeedProvider.notifier)
        .open(camera, notice: kTalkUnavailable),
  );

  final notifications = ref.read(notificationServiceProvider);
  final rings = notifications.rings.listen(controller.ring);
  final clears = notifications.clears.listen(controller.clear);
  final lifecycle = AppLifecycleListener(onStateChange: controller.onLifecycle);
  ref.onDispose(() {
    rings.cancel();
    clears.cancel();
    lifecycle.dispose();
  });
  return controller;
});
