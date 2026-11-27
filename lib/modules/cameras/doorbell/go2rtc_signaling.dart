import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// go2rtc's WebSocket API for [camera], on the same host as Frigate.
///
/// The WebSocket, not `POST /api/webrtc`: with `src=` go2rtc registers every
/// connection as a consumer, which is what lets a send-only Talk connection
/// reach the doorbell's backchannel. A POST picks the role from the offer and
/// would register that one as a producer.
Uri go2rtcSignalingUri(String frigateUrl, String camera) {
  final host = Uri.parse(frigateUrl).host;
  return Uri(
    scheme: 'ws',
    host: host,
    port: 1984,
    path: '/api/ws',
    queryParameters: {'src': camera},
  );
}

/// A frame from go2rtc, or the socket closing.
sealed class Go2rtcMessage {
  const Go2rtcMessage();
}

class Go2rtcAnswer extends Go2rtcMessage {
  final String sdp;
  const Go2rtcAnswer(this.sdp);
}

class Go2rtcCandidate extends Go2rtcMessage {
  final String candidate;
  const Go2rtcCandidate(this.candidate);
}

/// go2rtc refused, e.g. an unknown stream or no matching tracks.
class Go2rtcError extends Go2rtcMessage {
  final String message;
  const Go2rtcError(this.message);
}

/// The socket closed. Always the last message.
class Go2rtcClosed extends Go2rtcMessage {
  const Go2rtcClosed();
}

/// One WebRTC negotiation over go2rtc's v1 messages: `webrtc/offer` out,
/// `webrtc/answer`, `webrtc/candidate` and `error` back. Candidates go both
/// ways; an empty value ends ours.
class Go2rtcSignaling {
  Go2rtcSignaling(this._channel);

  final WebSocketChannel _channel;

  /// Single subscription. Frames that are not JSON or not one of the types
  /// above are dropped.
  late final Stream<Go2rtcMessage> messages = _messages();

  Stream<Go2rtcMessage> _messages() async* {
    try {
      await for (final frame in _channel.stream) {
        final message = _parse(frame);
        if (message != null) yield message;
      }
    } catch (_) {
      // A socket error ends the negotiation the same way a close does.
    }
    yield const Go2rtcClosed();
  }

  static Go2rtcMessage? _parse(dynamic frame) {
    if (frame is! String) return null;
    final Object? json;
    try {
      json = jsonDecode(frame);
    } on FormatException {
      return null;
    }
    if (json is! Map) return null;
    final value = json['value'];
    if (value is! String) return null;
    return switch (json['type']) {
      'webrtc/answer' => Go2rtcAnswer(value),
      'webrtc/candidate' => Go2rtcCandidate(value),
      'error' => Go2rtcError(value),
      _ => null,
    };
  }

  void sendOffer(String sdp) => _send('webrtc/offer', sdp);

  /// Null ends our candidates.
  void sendCandidate(String? candidate) =>
      _send('webrtc/candidate', candidate ?? '');

  void _send(String type, String value) =>
      _channel.sink.add(jsonEncode({'type': type, 'value': value}));

  Future<void> close() => _channel.sink.close();
}
