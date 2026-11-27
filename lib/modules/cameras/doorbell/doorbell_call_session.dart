import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../utils/logger.dart';
import 'doorbell_platform.dart';
import 'rtc_client.dart';

/// How long either WebRTC connection may take before it counts as failed.
const kDoorbellConnectTimeout = Duration(seconds: 5);

/// What a Talk toggle ended as.
enum TalkResult { on, off, failed, micDenied }

/// One open doorbell call: the platform hold and the two WebRTC links.
///
/// [start] takes the hold (satellite paused, playback muted, screen on)
/// before any doorbell audio can play. [dispose] releases it on every path,
/// in a `finally`, whatever closing the links does. The microphone opens
/// only in [setTalk].
class DoorbellCallSession {
  static const _tag = 'Doorbell';

  DoorbellCallSession({
    required Uri signaling,
    required RtcClient rtc,
    required DoorbellPlatform platform,
    required void Function(bool active) muteHearthPlayback,
    void Function()? onLost,
    void Function()? onTalkLost,
  })  : _signaling = signaling,
        _rtc = rtc,
        _platform = platform,
        _mute = muteHearthPlayback,
        _onLost = onLost,
        _onTalkLost = onTalkLost;

  final Uri _signaling;
  final RtcClient _rtc;
  final DoorbellPlatform _platform;
  final void Function(bool) _mute;
  final void Function()? _onLost;
  final void Function()? _onTalkLost;

  final _media = ValueNotifier<RtcReceiveLink?>(null);
  final _talking = ValueNotifier<bool>(false);
  RtcTalkLink? _talk;
  Future<TalkResult> _talkQueue = Future.value(TalkResult.off);
  bool _begun = false;
  bool _disposed = false;

  /// Completed by [dispose], so a Talk still connecting lets go of the
  /// microphone at once rather than when it connects or times out.
  final _abort = Completer<void>();
  Future<void>? _disposing;

  /// The doorbell's video and audio, once connected.
  ValueListenable<RtcReceiveLink?> get media => _media;

  /// The microphone is sending.
  ValueListenable<bool> get talking => _talking;

  /// Takes the hold, then connects. False on any failure; the hold is still
  /// released by [dispose].
  Future<bool> start() async {
    _begun = true;
    try {
      await _platform.begin();
    } catch (e) {
      Log.e(_tag, 'hold refused: $e');
      return false;
    }
    // A hang up during begin has already unmuted; muting now would stick.
    if (_disposed) return false;
    _mute(true);

    final RtcReceiveLink link;
    try {
      link = await _rtc.receive(_signaling, timeout: kDoorbellConnectTimeout);
    } catch (e) {
      Log.w(_tag, 'doorbell stream unavailable: $e');
      return false;
    }
    if (_disposed) {
      await _closeQuietly(link.close);
      return false;
    }
    _media.value = link;
    link.lost.listen((_) => _onLost?.call());
    return true;
  }

  /// Turns the microphone on or off. Calls are serialized, so a double tap
  /// opens one send connection.
  Future<TalkResult> setTalk(bool on) =>
      _talkQueue = _talkQueue.then((_) => _setTalk(on));

  Future<TalkResult> _setTalk(bool on) async {
    if (!on) {
      await _closeTalk();
      return TalkResult.off;
    }
    if (_disposed) return TalkResult.off;
    if (_talk != null) return TalkResult.on;

    final RtcTalkLink link;
    try {
      link = await _rtc.talk(_signaling,
          timeout: kDoorbellConnectTimeout, abort: _abort.future);
    } on MicDenied {
      return TalkResult.micDenied;
    } catch (e) {
      Log.w(_tag, 'talk unavailable: $e');
      return TalkResult.failed;
    }
    if (_disposed) {
      await _closeQuietly(link.close);
      return TalkResult.off;
    }
    _talk = link;
    _talking.value = true;
    link.lost.listen((_) async {
      if (!identical(_talk, link)) return;
      await _closeTalk();
      _onTalkLost?.call();
    });
    return TalkResult.on;
  }

  Future<void> _closeTalk() async {
    final link = _talk;
    _talk = null;
    _talking.value = false;
    if (link != null) await _closeQuietly(link.close);
  }

  /// Ends the call: the microphone, then the doorbell stream, then the hold.
  /// Idempotent.
  Future<void> dispose() => _disposing ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _abort.complete();
    try {
      await _closeTalk();
      final media = _media.value;
      _media.value = null;
      if (media != null) await _closeQuietly(media.close);
    } finally {
      if (_begun) await _platform.end();
      _mute(false);
    }
  }

  static Future<void> _closeQuietly(Future<void> Function() close) async {
    try {
      await close();
    } catch (e) {
      Log.w(_tag, 'close failed: $e');
    }
  }
}
