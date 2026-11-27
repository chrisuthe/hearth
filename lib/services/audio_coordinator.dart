import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/logger.dart';
import 'video/hearth_video_player.dart';
import 'voice_satellite_bridge.dart';

/// Gets Hearth's own playback out of the way of the in-app voice satellite,
/// per the "Echo and ducking" table in
/// `docs/specs/2026-10-13-android-native-voice-satellite-design.md`.
///
/// Android only. The Pi keeps [VoiceDucker], which ducks Sendspin from the
/// Home Assistant entity; there is no satellite in the process to listen to.
///
/// The service's `duck` event is the main signal: it rises with the wake word
/// and a timer ring, while the state is still idle. The pipeline states hold
/// the duck as well, so a lost `duck` event cannot leave the command competing
/// with music. A stopped service, a lost Home Assistant connection or a health
/// report drops the request, because Ava does not call `unDuck` on those
/// paths and the service may be gone before it could say so.
class AudioCoordinator {
  static const _tag = 'AudioCoordinator';

  /// media_kit level while ducked; Sendspin's mute is native and not here.
  /// 0.20 ≈ -14 dB, the level the Pi ducks Sendspin to.
  static const double duckFactor = 0.20;

  static const _activeStates = {'listening', 'processing', 'responding'};

  final ValueNotifier<double> _playback;
  StreamSubscription<bool>? _duckSub;
  StreamSubscription<VoiceSatelliteStatus>? _statusSub;

  bool _requested = false;
  bool _callActive = false;
  VoiceSatelliteStatus _status = const VoiceSatelliteStatus();

  AudioCoordinator(this._playback);

  bool get ducked => _playback.value < 1.0;

  void start({
    required Stream<bool> duck,
    required Stream<VoiceSatelliteStatus> status,
    VoiceSatelliteStatus initial = const VoiceSatelliteStatus(),
  }) {
    _status = initial;
    _duckSub = duck.listen((active) {
      _requested = active;
      _apply();
    });
    _statusSub = status.listen(_onStatus);
  }

  /// A doorbell call is open: Hearth's own playback goes silent, whatever
  /// the voice satellite is doing, so it neither leaks into the call's
  /// microphone nor drowns out the visitor.
  void setCallActive(bool active) {
    if (_callActive == active) return;
    _callActive = active;
    Log.i(
      _tag,
      active
          ? 'Doorbell call → muting playback'
          : 'Doorbell call ended → restoring playback',
    );
    _apply();
  }

  void _onStatus(VoiceSatelliteStatus status) {
    final newHealth =
        status.health != null && !identical(status.health, _status.health);
    if (!status.running || !status.connected || newHealth) _requested = false;
    _status = status;
    _apply();
  }

  void _apply() {
    final active =
        _status.running &&
        _status.connected &&
        (_requested || _activeStates.contains(_status.state));
    _set(_callActive ? 0.0 : (active ? duckFactor : 1.0));
  }

  void _set(double factor) {
    if (_playback.value == factor) return;
    _playback.value = factor;
    // setCallActive logs the call's own changes.
    if (_callActive) return;
    Log.i(
      _tag,
      factor < 1.0
          ? 'Voice active → ducking playback'
          : 'Voice idle → restoring playback',
    );
  }

  void dispose() {
    _duckSub?.cancel();
    _statusSub?.cancel();
    _callActive = false;
    _set(1.0);
  }
}

final audioCoordinatorProvider = Provider<AudioCoordinator>((ref) {
  final bridge = ref.watch(voiceSatelliteBridgeProvider);
  final coordinator = AudioCoordinator(playbackDuck)
    ..start(
      duck: bridge.duckStream,
      status: bridge.statusStream,
      initial: bridge.status,
    );
  ref.onDispose(coordinator.dispose);
  return coordinator;
});
