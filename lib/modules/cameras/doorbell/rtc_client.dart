import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../utils/logger.dart';
import 'go2rtc_signaling.dart';

/// A WebRTC connection to go2rtc could not be made: refused, unreachable or
/// not connected in time.
class RtcUnavailable implements Exception {
  final String reason;
  const RtcUnavailable(this.reason);

  @override
  String toString() => 'RtcUnavailable: $reason';
}

/// The microphone could not be opened, usually because `RECORD_AUDIO` was
/// denied.
class MicDenied implements Exception {
  const MicDenied();
}

/// The doorbell's video and audio, playing.
abstract class RtcReceiveLink {
  Widget buildView();

  /// Fires once if the connection fails after it was up.
  Stream<void> get lost;
  Future<void> close();
}

/// The microphone, sending to the doorbell.
abstract class RtcTalkLink {
  /// Fires once if the connection fails after it was up.
  Stream<void> get lost;
  Future<void> close();
}

/// Opens the two connections of a doorbell call. Injected so the call logic
/// can be tested without a real peer.
abstract class RtcClient {
  Future<RtcReceiveLink> receive(Uri signaling, {required Duration timeout});

  /// Opens the microphone. Throws [MicDenied] or [RtcUnavailable].
  Future<RtcTalkLink> talk(Uri signaling, {required Duration timeout});
}

/// [RtcClient] over flutter_webrtc and go2rtc's WebSocket signalling.
///
/// Audio plays as media (loudspeaker, media volume, audio mode left at
/// normal) and echo cancellation is WebRTC's software canceller, which takes
/// WebRTC's own playout as its reference. Platform AEC is off: it is tuned
/// for the communication mode this avoids.
class FlutterWebrtcClient implements RtcClient {
  static const _tag = 'DoorbellRtc';
  static Future<void>? _initialized;

  // flutter_webrtc on Android reads only `mandatory`/`optional` audio
  // constraints; W3C-style top-level keys are ignored.
  static const _micConstraints = <String, dynamic>{
    'audio': {
      'mandatory': {
        'echoCancellation': 'true',
        'googEchoCancellation': 'true',
        'noiseSuppression': 'true',
        'googNoiseSuppression': 'true',
        'autoGainControl': 'true',
        'googAutoGainControl': 'true',
        'googHighpassFilter': 'true',
      },
      'optional': <dynamic>[],
    },
    'video': false,
  };

  static Future<void> _initialize() => _initialized ??= WebRTC.initialize(
        options: {
          'androidAudioConfiguration': AndroidAudioConfiguration.media.toMap(),
          'androidUseHardwareAudioProcessing': false,
        },
      );

  @override
  Future<RtcReceiveLink> receive(Uri signaling,
      {required Duration timeout}) async {
    await _initialize();
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    final pc = await createPeerConnection({'bundlePolicy': 'max-bundle'});
    MediaStream? remote;
    pc.onTrack = (event) async {
      if (event.streams.isNotEmpty) {
        renderer.srcObject = event.streams.first;
        return;
      }
      remote ??= await createLocalMediaStream('doorbell');
      await remote!.addTrack(event.track);
      renderer.srcObject = remote;
    };
    final recvOnly =
        RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly);
    await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo, init: recvOnly);
    await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly));

    final link = _WebrtcLink(pc, onClose: () async {
      renderer.srcObject = null;
      await renderer.dispose();
      await remote?.dispose();
    });
    try {
      await _negotiate(pc, signaling, timeout, link);
    } catch (_) {
      await link.close();
      rethrow;
    }
    return _ReceiveLink(link, renderer);
  }

  @override
  Future<RtcTalkLink> talk(Uri signaling, {required Duration timeout}) async {
    await _initialize();
    final MediaStream mic;
    try {
      mic = await navigator.mediaDevices.getUserMedia(_micConstraints);
    } catch (e) {
      Log.w(_tag, 'microphone unavailable: $e');
      throw const MicDenied();
    }
    final track = mic.getAudioTracks().firstOrNull;
    if (track == null) {
      await mic.dispose();
      throw const MicDenied();
    }

    RTCPeerConnection? pc;
    _WebrtcLink? link;
    Future<void> releaseMic() async {
      for (final t in mic.getTracks()) {
        await t.stop();
      }
      await mic.dispose();
    }

    try {
      pc = await createPeerConnection({'bundlePolicy': 'max-bundle'});
      final transceiver = await pc.addTransceiver(
        track: track,
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(
            direction: TransceiverDirection.SendOnly, streams: [mic]),
      );
      link = _WebrtcLink(pc, onClose: releaseMic);
      await _negotiate(pc, signaling, timeout, link);
      // As the Advanced Camera Card checks: a doorbell without a backchannel
      // connects but never takes the audio.
      final direction = await transceiver.getCurrentDirection();
      if (direction != TransceiverDirection.SendOnly &&
          direction != TransceiverDirection.SendRecv) {
        throw const RtcUnavailable('no two-way audio');
      }
      return _TalkLink(link);
    } catch (_) {
      if (link != null) {
        await link.close();
      } else {
        await pc?.close();
        await releaseMic();
      }
      rethrow;
    }
  }

  /// Offers over go2rtc's WebSocket and waits for `connected`. The socket
  /// is closed once connected, as the Advanced Camera Card does: the
  /// connection no longer needs it.
  static Future<void> _negotiate(RTCPeerConnection pc, Uri uri,
      Duration timeout, _WebrtcLink link) async {
    final connected = Completer<void>();
    void fail(String reason) {
      if (!connected.isCompleted) {
        connected.completeError(RtcUnavailable(reason));
      }
    }

    final WebSocketChannel channel;
    try {
      channel = WebSocketChannel.connect(uri);
      await channel.ready.timeout(timeout);
    } catch (e) {
      throw RtcUnavailable('go2rtc unreachable: $e');
    }
    final signaling = Go2rtcSignaling(channel);

    var remoteSet = false;
    final early = <String>[];
    Future<void> addRemote(String candidate) => pc
        .addCandidate(RTCIceCandidate(candidate, '0', 0))
        .catchError((Object e) => Log.w(_tag, 'candidate rejected: $e'));

    final sub = signaling.messages.listen((message) async {
      switch (message) {
        case Go2rtcAnswer(:final sdp):
          try {
            await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
            remoteSet = true;
            for (final c in early) {
              await addRemote(c);
            }
            early.clear();
          } catch (e) {
            fail('answer rejected: $e');
          }
        case Go2rtcCandidate(:final candidate):
          if (candidate.isEmpty) return;
          if (remoteSet) {
            await addRemote(candidate);
          } else {
            early.add(candidate);
          }
        case Go2rtcError(:final message):
          fail('go2rtc: $message');
        case Go2rtcClosed():
          fail('signalling closed');
      }
    });

    pc.onIceCandidate = (c) => signaling.sendCandidate(c.candidate);
    pc.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        signaling.sendCandidate(null);
      }
    };
    pc.onConnectionState = (state) {
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          if (!connected.isCompleted) connected.complete();
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          // `disconnected` can recover on its own; `failed` cannot.
          if (connected.isCompleted) {
            link.markLost();
          } else {
            fail('connection failed');
          }
        default:
      }
    };

    try {
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      signaling.sendOffer(offer.sdp ?? '');
      await connected.future.timeout(timeout,
          onTimeout: () => throw const RtcUnavailable('connect timed out'));
    } on RtcUnavailable {
      rethrow;
    } catch (e) {
      throw RtcUnavailable('$e');
    } finally {
      await sub.cancel();
      unawaited(signaling.close().catchError((_) {}));
    }
  }
}

class _WebrtcLink {
  _WebrtcLink(this._pc, {required Future<void> Function() onClose})
      : _onClose = onClose;

  final RTCPeerConnection _pc;
  final Future<void> Function() _onClose;
  final _lost = StreamController<void>.broadcast();
  bool _closed = false;

  Stream<void> get lost => _lost.stream;

  void markLost() {
    if (!_closed && !_lost.isClosed) _lost.add(null);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _pc.onConnectionState = null;
    try {
      await _pc.close();
    } finally {
      await _onClose();
      await _lost.close();
    }
  }
}

class _ReceiveLink implements RtcReceiveLink {
  _ReceiveLink(this._link, this._renderer);
  final _WebrtcLink _link;
  final RTCVideoRenderer _renderer;

  @override
  Widget buildView() => RTCVideoView(_renderer,
      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain);

  @override
  Stream<void> get lost => _link.lost;

  @override
  Future<void> close() => _link.close();
}

class _TalkLink implements RtcTalkLink {
  _TalkLink(this._link);
  final _WebrtcLink _link;

  @override
  Stream<void> get lost => _link.lost;

  @override
  Future<void> close() => _link.close();
}

final rtcClientProvider = Provider<RtcClient>((ref) => FlutterWebrtcClient());
