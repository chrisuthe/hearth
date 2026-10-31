import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/models/hearth_notification.dart';

void main() {
  group('HearthNotification.fromIngest', () {
    test('parses the new fields', () {
      final n = HearthNotification.fromIngest({
        'title': 'Person',
        'tag': 'front_door',
        'camera': 'front_door',
        'image': '/api/camera_proxy/camera.front_door',
        'image_refresh': 3,
        'timeout': 180,
      })!;
      expect(n.id, 'tag-front_door');
      expect(n.tag, 'front_door');
      expect(n.camera, 'front_door');
      expect(n.image, '/api/camera_proxy/camera.front_door');
      expect(n.imageRefresh, const Duration(seconds: 3));
      expect(n.timeout, const Duration(seconds: 180));
      expect(n.sticky, isTrue);
    });

    test('image_refresh under 1 becomes 1', () {
      final n = HearthNotification.fromIngest(
          {'title': 'x', 'image': '/a.jpg', 'image_refresh': 0.2})!;
      expect(n.imageRefresh, const Duration(seconds: 1));
    });

    test('image_refresh with no timeout gets 10 minutes', () {
      final n = HearthNotification.fromIngest(
          {'title': 'x', 'image': '/a.jpg', 'image_refresh': 3})!;
      expect(n.timeout, const Duration(minutes: 10));
    });

    test('an image with no refresh gets no default timeout', () {
      final n =
          HearthNotification.fromIngest({'title': 'x', 'image': '/a.jpg'})!;
      expect(n.imageRefresh, isNull);
      expect(n.timeout, isNull);
    });

    test('timeout beats sticky:false', () {
      final n = HearthNotification.fromIngest(
          {'title': 'x', 'sticky': false, 'timeout': 30})!;
      expect(n.sticky, isTrue);
      expect(n.timeout, const Duration(seconds: 30));
    });

    test('wrong types and empty strings count as absent', () {
      final n = HearthNotification.fromIngest({
        'title': 'x',
        'image': 5,
        'image_refresh': 'abc',
        'camera': '',
        'tag': '  ',
        'timeout': -1,
      })!;
      expect(n.image, isNull);
      expect(n.imageRefresh, isNull);
      expect(n.camera, isNull);
      expect(n.tag, isNull);
      expect(n.timeout, isNull);
      expect(n.id, startsWith('ext-'));
    });

    test('non-finite and absurdly long durations count as absent', () {
      for (final bad in <Object>[
        'Infinity',
        'NaN',
        double.infinity,
        double.nan,
        1e300,
      ]) {
        final n = HearthNotification.fromIngest(
            {'title': 'x', 'timeout': bad, 'image_refresh': bad})!;
        expect(n.timeout, isNull, reason: 'timeout: $bad');
        expect(n.imageRefresh, isNull, reason: 'image_refresh: $bad');
      }
    });

    test('numeric strings are accepted', () {
      final n = HearthNotification.fromIngest(
          {'title': 'x', 'image_refresh': '3', 'timeout': '45'})!;
      expect(n.imageRefresh, const Duration(seconds: 3));
      expect(n.timeout, const Duration(seconds: 45));
    });

    test('existing payload is unchanged', () {
      final info = HearthNotification.fromIngest({'title': 'x'})!;
      expect(info.sticky, isFalse);
      expect(info.image, isNull);
      expect(info.camera, isNull);
      expect(info.tag, isNull);
      expect(info.timeout, isNull);
      expect(info.imageRefresh, isNull);
      expect(info.id, startsWith('ext-'));

      final alert =
          HearthNotification.fromIngest({'title': 'x', 'priority': 'alert'})!;
      expect(alert.sticky, isTrue);
    });
  });
}
