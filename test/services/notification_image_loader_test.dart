import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/services/notification_image_loader.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({
    List<List<int>>? chunks,
    this.status = 200,
    this.contentType = 'image/jpeg',
    this.error,
  }) : chunks = chunks ??
            const [
              [1, 2, 3]
            ];

  final List<List<int>> chunks;
  final int status;
  final String contentType;
  final Object? error;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    if (error != null) throw error!;
    return ResponseBody(
      Stream.fromIterable(chunks.map(Uint8List.fromList)),
      status,
      headers: {
        Headers.contentTypeHeader: [contentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  const ha = 'http://ha.local:8123';

  NotificationImageLoader loader(
    _FakeAdapter adapter, {
    String haUrl = ha,
    String haToken = 't',
  }) =>
      NotificationImageLoader(
        haUrl: haUrl,
        haToken: haToken,
        dio: Dio()..httpClientAdapter = adapter,
      );

  String? authOf(RequestOptions r) => r.headers['Authorization'] as String?;

  test('relative path goes to HA with the token', () async {
    final adapter = _FakeAdapter();
    final bytes =
        await loader(adapter).fetch('/api/camera_proxy/camera.front_door');
    expect(bytes, [1, 2, 3]);
    expect(adapter.requests.single.uri.toString(),
        'http://ha.local:8123/api/camera_proxy/camera.front_door');
    expect(authOf(adapter.requests.single), 'Bearer t');
  });

  test('same-origin absolute URL gets the token', () async {
    final adapter = _FakeAdapter();
    await loader(adapter).fetch('http://ha.local:8123/local/a.jpg');
    expect(authOf(adapter.requests.single), 'Bearer t');
  });

  test('other origin gets no token', () async {
    final adapter = _FakeAdapter();
    final bytes = await loader(adapter).fetch('http://photos.local/a.jpg');
    expect(bytes, [1, 2, 3]);
    expect(authOf(adapter.requests.single), isNull);
  });

  test('different port counts as another origin', () async {
    final adapter = _FakeAdapter();
    await loader(adapter).fetch('http://ha.local:9000/a.jpg');
    expect(authOf(adapter.requests.single), isNull);
  });

  test('different scheme counts as another origin', () async {
    final adapter = _FakeAdapter();
    await loader(adapter).fetch('https://ha.local:8123/a.jpg');
    expect(authOf(adapter.requests.single), isNull);
  });

  test('a lookalike host using userinfo gets no token', () async {
    final adapter = _FakeAdapter();
    await loader(adapter).fetch('http://ha.local:8123@evil.example/a.jpg');
    expect(adapter.requests.single.uri.host, 'evil.example');
    expect(authOf(adapter.requests.single), isNull);
  });

  test('protocol-relative path never gets the token', () async {
    final adapter = _FakeAdapter();
    await loader(adapter).fetch('//evil.example/x');
    for (final r in adapter.requests) {
      expect(authOf(r), isNull);
    }
  });

  test('backslash path never gets the token', () async {
    final adapter = _FakeAdapter();
    await loader(adapter).fetch(r'/\evil.example/x');
    for (final r in adapter.requests) {
      expect(authOf(r), isNull);
    }
  });

  test('non-http scheme is not fetched', () async {
    final adapter = _FakeAdapter();
    expect(await loader(adapter).fetch('file:///etc/passwd'), isNull);
    expect(await loader(adapter).fetch('not a url'), isNull);
    expect(adapter.requests, isEmpty);
  });

  test('relative path with no HA URL or token is not fetched', () async {
    final adapter = _FakeAdapter();
    expect(await loader(adapter, haUrl: '').fetch('/a.jpg'), isNull);
    expect(await loader(adapter, haToken: '').fetch('/a.jpg'), isNull);
    expect(adapter.requests, isEmpty);
  });

  test('redirects are not followed when the token is attached', () async {
    final adapter = _FakeAdapter();
    await loader(adapter).fetch('/a.jpg');
    expect(adapter.requests.single.followRedirects, isFalse);
  });

  test('a redirect response with the token attached returns null', () async {
    final adapter = _FakeAdapter(status: 302);
    expect(await loader(adapter).fetch('/a.jpg'), isNull);
    expect(adapter.requests, hasLength(1));
  });

  test('non-image response returns null', () async {
    final adapter = _FakeAdapter(contentType: 'text/html');
    expect(await loader(adapter).fetch('/a.jpg'), isNull);
  });

  test('error status returns null', () async {
    final adapter = _FakeAdapter(status: 401);
    expect(await loader(adapter).fetch('/a.jpg'), isNull);
  });

  test('response over the size cap returns null', () async {
    final adapter = _FakeAdapter(
      chunks: List.generate(11, (_) => Uint8List(1024 * 1024)),
    );
    expect(await loader(adapter).fetch('/a.jpg'), isNull);
  });

  test('adapter exception returns null', () async {
    final adapter = _FakeAdapter(error: StateError('network down'));
    expect(await loader(adapter).fetch('/a.jpg'), isNull);
  });
}
