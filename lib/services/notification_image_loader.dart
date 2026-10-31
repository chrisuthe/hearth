import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/hub_config.dart';
import '../utils/logger.dart';

/// Largest picture a notification may fetch.
const int kMaxNotificationImageBytes = 10 * 1024 * 1024;

/// Fetches the picture a notification carries in its `image` field.
///
/// A path starting with `/` is read from Home Assistant, which is how an
/// automation attaches `/api/camera_proxy/camera.front_door`. Any other http(s)
/// URL is fetched as given. HA's token only ever goes to HA's own origin, and
/// redirects aren't followed while it's attached, so a payload or a redirect
/// can't carry it to another host.
class NotificationImageLoader {
  NotificationImageLoader({
    required String haUrl,
    required String haToken,
    Dio? dio,
  })  : _haUri = Uri.tryParse(haUrl.trim()),
        _haToken = haToken,
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 10),
            ));

  final Uri? _haUri;
  final String _haToken;
  final Dio _dio;

  /// The picture's bytes, or null if it can't be fetched or isn't an image.
  Future<Uint8List?> fetch(String image) async {
    final uri = _resolve(image);
    if (uri == null) return null;
    final sendToken = _haToken.isNotEmpty && _isHaOrigin(uri);
    final cancel = CancelToken();
    try {
      final response = await _dio.getUri<ResponseBody>(
        uri,
        cancelToken: cancel,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: !sendToken,
          headers: {if (sendToken) 'Authorization': 'Bearer $_haToken'},
        ),
      );
      final contentType = response.headers.value(Headers.contentTypeHeader);
      if (contentType == null || !contentType.startsWith('image/')) {
        cancel.cancel();
        return null;
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.data!.stream) {
        bytes.add(chunk);
        if (bytes.length > kMaxNotificationImageBytes) {
          cancel.cancel();
          Log.w('Notification', 'Picture from ${uri.host} is too large');
          return null;
        }
      }
      return bytes.takeBytes();
    } catch (e) {
      Log.w('Notification', 'Picture from ${uri.host} failed: ${e.runtimeType}');
      return null;
    }
  }

  Uri? _resolve(String image) {
    // `//host/path` and `/\host/path` read as paths but can reach another host.
    if (image.startsWith('//') || image.contains(r'\')) return null;
    if (image.startsWith('/')) {
      final ha = _haUri;
      if (ha == null || !ha.hasAuthority || _haToken.isEmpty) return null;
      return ha.resolve(image);
    }
    final uri = Uri.tryParse(image);
    if (uri == null || !uri.hasAuthority) return null;
    return uri.isScheme('http') || uri.isScheme('https') ? uri : null;
  }

  bool _isHaOrigin(Uri uri) {
    final ha = _haUri;
    return ha != null &&
        uri.scheme == ha.scheme &&
        uri.host == ha.host &&
        uri.port == ha.port;
  }

  void dispose() => _dio.close(force: true);
}

final notificationImageLoaderProvider =
    Provider<NotificationImageLoader>((ref) {
  final loader = NotificationImageLoader(
    haUrl: ref.watch(hubConfigProvider.select((c) => c.haUrl)),
    haToken: ref.watch(hubConfigProvider.select((c) => c.haToken)),
  );
  ref.onDispose(loader.dispose);
  return loader;
});
