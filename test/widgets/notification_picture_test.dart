import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/modules/cameras/camera_feed_overlay.dart';
import 'package:hearth/services/notification_image_loader.dart';
import 'package:hearth/widgets/notification_picture.dart';

final _frameA = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAEElEQVR4nGNwCEiAIwacHADaBwtBoHgf+wAAAABJRU5ErkJggg==');
final _frameB = Uint8List.fromList([..._frameA, 0]);

class _ScriptedLoader extends NotificationImageLoader {
  _ScriptedLoader(this.respond) : super(haUrl: '', haToken: '');

  final Future<Uint8List?> Function(int call, String image) respond;
  final images = <String>[];

  @override
  Future<Uint8List?> fetch(String image) {
    images.add(image);
    return respond(images.length, image);
  }
}

Uint8List _shownBytes(WidgetTester tester) {
  final provider = tester.widget<Image>(find.byType(Image)).image;
  final memory = provider is ResizeImage ? provider.imageProvider : provider;
  return (memory as MemoryImage).bytes;
}

void main() {
  Future<ProviderContainer> pump(
    WidgetTester tester,
    _ScriptedLoader loader, {
    String image = '/a.jpg',
    Duration? refresh,
    ValueChanged<Uint8List>? onFrame,
  }) async {
    final container = ProviderContainer(overrides: [
      notificationImageLoaderProvider.overrideWithValue(loader),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: NotificationPicture(
                image: image, refresh: refresh, onFrame: onFrame),
          ),
        ),
      ),
    ));
    return container;
  }

  testWidgets('shows the fetched frame', (tester) async {
    Uint8List? reported;
    await pump(tester, _ScriptedLoader((_, _) async => _frameA),
        onFrame: (f) => reported = f);
    await tester.pump();
    expect(_shownBytes(tester), _frameA);
    expect(reported, _frameA);
  });

  testWidgets('reserves its space while the first frame loads', (tester) async {
    final pending = Completer<Uint8List?>();
    await pump(tester, _ScriptedLoader((_, _) => pending.future));
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(tester.getSize(find.byType(NotificationPicture)).height,
        greaterThan(0));
    pending.complete(null);
    await tester.pump();
  });

  testWidgets('refresh replaces the frame', (tester) async {
    final loader =
        _ScriptedLoader((call, _) async => call == 1 ? _frameA : _frameB);
    await pump(tester, loader, refresh: const Duration(seconds: 3));
    await tester.pump();
    expect(_shownBytes(tester), _frameA);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(loader.images, hasLength(2));
    expect(_shownBytes(tester), _frameB);
  });

  testWidgets('no refresh fetches once', (tester) async {
    final loader = _ScriptedLoader((_, _) async => _frameA);
    await pump(tester, loader);
    await tester.pump(const Duration(minutes: 1));
    expect(loader.images, hasLength(1));
  });

  testWidgets('a failed refresh keeps the last frame', (tester) async {
    final loader =
        _ScriptedLoader((call, _) async => call == 1 ? _frameA : null);
    await pump(tester, loader, refresh: const Duration(seconds: 3));
    await tester.pump();

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(loader.images, hasLength(2));
    expect(_shownBytes(tester), _frameA);
  });

  testWidgets('never loading collapses to nothing', (tester) async {
    await pump(tester, _ScriptedLoader((_, _) async => null));
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(tester.getSize(find.byType(NotificationPicture)).height, 0);
  });

  testWidgets('a later success recovers a picture that never loaded',
      (tester) async {
    final loader =
        _ScriptedLoader((call, _) async => call == 1 ? null : _frameA);
    await pump(tester, loader, refresh: const Duration(seconds: 3));
    await tester.pump();
    expect(find.byType(Image), findsNothing);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    expect(_shownBytes(tester), _frameA);
  });

  testWidgets('fetches do not overlap', (tester) async {
    final slow = Completer<Uint8List?>();
    final loader = _ScriptedLoader((_, _) => slow.future);
    await pump(tester, loader, refresh: const Duration(seconds: 3));

    await tester.pump(const Duration(seconds: 10));
    expect(loader.images, hasLength(1));

    slow.complete(_frameA);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(loader.images, hasLength(2));
  });

  testWidgets('polling pauses while a feed is open and resumes after',
      (tester) async {
    final loader = _ScriptedLoader((_, _) async => _frameA);
    final c = await pump(tester, loader, refresh: const Duration(seconds: 3));
    await tester.pump();
    expect(loader.images, hasLength(1));

    c.read(cameraFeedProvider.notifier).open('front_door');
    await tester.pump(const Duration(seconds: 9));
    expect(loader.images, hasLength(1));

    c.read(cameraFeedProvider.notifier).close();
    await tester.pump(const Duration(seconds: 3));
    expect(loader.images, hasLength(2));
  });

  testWidgets('dispose during a fetch does not throw', (tester) async {
    final slow = Completer<Uint8List?>();
    await pump(tester, _ScriptedLoader((_, _) => slow.future));
    await tester.pumpWidget(const SizedBox.shrink());
    slow.complete(_frameA);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('polling stops when removed', (tester) async {
    final loader = _ScriptedLoader((_, _) async => _frameA);
    await pump(tester, loader, refresh: const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 30));
    expect(loader.images, hasLength(1));
  });

  testWidgets('a changed image address fetches the new one', (tester) async {
    final loader = _ScriptedLoader((_, _) async => _frameA);
    final container = ProviderContainer(overrides: [
      notificationImageLoaderProvider.overrideWithValue(loader),
    ]);
    addTearDown(container.dispose);
    Widget host(String image) => UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: NotificationPicture(image: image),
              ),
            ),
          ),
        );
    await tester.pumpWidget(host('/a.jpg'));
    await tester.pumpWidget(host('/b.jpg'));
    await tester.pump();
    expect(loader.images, ['/a.jpg', '/b.jpg']);
  });
}
