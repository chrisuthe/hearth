import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/modules/cameras/doorbell/go2rtc_signaling.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _FakeChannel implements WebSocketChannel {
  final incoming = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];
  late final _sink = _FakeSink(sent);

  @override
  Stream<dynamic> get stream => incoming.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this._sent);
  final List<Map<String, dynamic>> _sent;
  bool closed = false;

  @override
  void add(dynamic data) =>
      _sent.add(jsonDecode(data as String) as Map<String, dynamic>);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async =>
      closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('signalling URI points at go2rtc on the Frigate host', () {
    expect(
      go2rtcSignalingUri('http://10.0.2.2:5000', 'FrontDoorbell').toString(),
      'ws://10.0.2.2:1984/api/ws?src=FrontDoorbell',
    );
  });

  test('sendOffer writes a v1 offer', () {
    final channel = _FakeChannel();
    Go2rtcSignaling(channel).sendOffer('v=0...');
    expect(channel.sent.single, {'type': 'webrtc/offer', 'value': 'v=0...'});
  });

  test('sendCandidate(null) ends the candidates', () {
    final channel = _FakeChannel();
    final signaling = Go2rtcSignaling(channel)
      ..sendCandidate('candidate:1 1 udp 1 10.0.2.16 5000 typ host')
      ..sendCandidate(null);
    expect(channel.sent.last, {'type': 'webrtc/candidate', 'value': ''});
    expect(channel.sent.first['value'], startsWith('candidate:1'));
    expect(signaling, isNotNull);
  });

  test('incoming frames map to messages', () async {
    final channel = _FakeChannel();
    final messages = Go2rtcSignaling(channel).messages.toList();
    channel.incoming
      ..add(jsonEncode({'type': 'webrtc/answer', 'value': 'v=0 answer'}))
      ..add(jsonEncode({'type': 'webrtc/candidate', 'value': 'candidate:2'}))
      ..add(jsonEncode({'type': 'error', 'value': 'stream not found'}));
    await channel.incoming.close();

    final list = await messages;
    expect((list[0] as Go2rtcAnswer).sdp, 'v=0 answer');
    expect((list[1] as Go2rtcCandidate).candidate, 'candidate:2');
    expect((list[2] as Go2rtcError).message, 'stream not found');
    expect(list[3], isA<Go2rtcClosed>());
    expect(list, hasLength(4));
  });

  test('non-JSON and unknown frames are dropped', () async {
    final channel = _FakeChannel();
    final messages = Go2rtcSignaling(channel).messages.toList();
    channel.incoming
      ..add('not json')
      ..add(jsonEncode({'type': 'mse', 'value': 'x'}))
      ..add(jsonEncode({'type': 'webrtc/answer'}));
    await channel.incoming.close();

    expect(await messages, [isA<Go2rtcClosed>()]);
  });

  test('close closes the socket', () async {
    final channel = _FakeChannel();
    await Go2rtcSignaling(channel).close();
    expect(channel._sink.closed, isTrue);
  });
}
