import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/models/hearth_notification.dart';
import 'package:hearth/modules/cameras/camera_feed_overlay.dart';
import 'package:hearth/services/notification_image_loader.dart';
import 'package:hearth/services/notification_service.dart';
import 'package:hearth/widgets/notification_card.dart';
import 'package:hearth/widgets/notification_deck_overlay.dart';
import 'package:hearth/widgets/notification_picture.dart';

final _frame = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAEElEQVR4nGNwCEiAIwacHADaBwtBoHgf+wAAAABJRU5ErkJggg==');

class _FixedLoader extends NotificationImageLoader {
  _FixedLoader() : super(haUrl: '', haToken: '');

  @override
  Future<Uint8List?> fetch(String image) async => _frame;
}

HearthNotification _note({
  String? image,
  String? camera,
  String title = 'Person Detected at Front Door',
}) =>
    HearthNotification(
      id: 'tag-door',
      tag: 'door',
      source: NotificationSource.frigate,
      sourceLabel: 'FRIGATE',
      priority: NotificationPriority.info,
      title: title,
      body: '',
      sticky: true,
      timestamp: DateTime(2026, 10, 30, 7, 42),
      image: image,
      camera: camera,
    );

void main() {
  Widget host(Widget child) => ProviderScope(
        overrides: [
          notificationImageLoaderProvider.overrideWithValue(_FixedLoader()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(child: SizedBox(width: 600, child: child)),
          ),
        ),
      );

  group('NotificationCard', () {
    testWidgets('card with no image renders as it does today', (tester) async {
      await tester.pumpWidget(host(NotificationCard(
        notification: _note(),
        onDismiss: () {},
      )));
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(NotificationPicture), findsNothing);
      expect(find.text('Sticky'), findsOneWidget);
    });

    testWidgets('shows the picture above the title', (tester) async {
      await tester.pumpWidget(host(NotificationCard(
        notification: _note(image: '/a.jpg'),
        onDismiss: () {},
      )));
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(Image), findsOneWidget);
      expect(tester.getBottomLeft(find.byType(NotificationPicture)).dy,
          lessThanOrEqualTo(tester.getTopLeft(find.text('FRIGATE')).dy));
      // Edge to edge: only the card's 1px border sits above the picture.
      expect(tester.getTopLeft(find.byType(NotificationPicture)).dy,
          closeTo(tester.getTopLeft(find.byType(NotificationCard)).dy, 1));
    });

    testWidgets('tap fires onOpenFeed with the latest frame', (tester) async {
      Uint8List? opened;
      var tapped = 0;
      await tester.pumpWidget(host(NotificationCard(
        notification: _note(image: '/a.jpg', camera: 'front_door'),
        onDismiss: () {},
        onOpenFeed: (frame) {
          tapped++;
          opened = frame;
        },
      )));
      await tester.pump(const Duration(seconds: 2));

      await tester.tap(find.byType(NotificationPicture));
      await tester.pump();

      expect(tapped, 1);
      expect(opened, _frame);
    });

    testWidgets('tap with no camera does nothing', (tester) async {
      await tester.pumpWidget(host(NotificationCard(
        notification: _note(image: '/a.jpg'),
        onDismiss: () {},
      )));
      await tester.pump(const Duration(seconds: 2));
      expect(
        find.descendant(
          of: find.byType(NotificationCard),
          matching: find.byIcon(Icons.play_circle_outline),
        ),
        findsNothing,
      );
      await tester.tap(find.byType(NotificationPicture));
      await tester.pump();
      expect(find.text('Tap for live view'), findsNothing);
    });

    testWidgets('the close button dismisses without opening the feed',
        (tester) async {
      var dismissed = 0;
      var opened = 0;
      await tester.pumpWidget(host(NotificationCard(
        notification: _note(image: '/a.jpg', camera: 'front_door'),
        onDismiss: () => dismissed++,
        onOpenFeed: (_) => opened++,
      )));
      await tester.pump(const Duration(seconds: 2));

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();

      expect(dismissed, 1);
      expect(opened, 0);
    });

    testWidgets('Mute does not open the feed', (tester) async {
      var opened = 0;
      await tester.pumpWidget(host(NotificationCard(
        notification: _note(image: '/a.jpg', camera: 'front_door'),
        onDismiss: () {},
        onOpenFeed: (_) => opened++,
      )));
      await tester.pump(const Duration(seconds: 2));

      await tester.tap(find.text('Mute'));
      await tester.pump();

      expect(opened, 0);
      expect(find.text('Unmute'), findsOneWidget);
    });

    testWidgets('pill reads Tap for live view with a camera', (tester) async {
      await tester.pumpWidget(host(NotificationCard(
        notification: _note(image: '/a.jpg', camera: 'front_door'),
        onDismiss: () {},
        onOpenFeed: (_) {},
      )));
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Tap for live view'), findsOneWidget);
      expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
    });
  });

  group('NotificationDeckOverlay', () {
    late NotificationService service;

    // The provider disposes the service along with the container.
    setUp(() => service = NotificationService(playChime: (_) async {}));

    Future<ProviderContainer> pumpDeck(
      WidgetTester tester, {
      Size canvas = const Size(1184, 864),
    }) async {
      tester.view.physicalSize = canvas;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(overrides: [
        notificationServiceProvider.overrideWith((ref) => service),
        notificationImageLoaderProvider.overrideWithValue(_FixedLoader()),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Stack(children: [NotificationDeckOverlay(onWake: () {})]),
          ),
        ),
      ));
      return container;
    }

    testWidgets('tapping a camera card opens its feed with the frame',
        (tester) async {
      service.ingest(_note(image: '/a.jpg', camera: 'front_door'));
      final c = await pumpDeck(tester);
      await tester.pump(const Duration(seconds: 2));

      await tester.tap(find.byType(NotificationPicture));
      await tester.pump();

      final request = c.read(cameraFeedProvider);
      expect(request?.camera, 'front_door');
      expect(request?.frame, _frame);
    });

    testWidgets('a card with no camera opens no feed', (tester) async {
      service.ingest(_note(image: '/a.jpg'));
      final c = await pumpDeck(tester);
      await tester.pump(const Duration(seconds: 2));

      await tester.tap(find.byType(NotificationPicture));
      await tester.pump();

      expect(c.read(cameraFeedProvider), isNull);
    });

    testWidgets('a picture card is narrower than the deck in landscape',
        (tester) async {
      service.ingest(_note(image: '/a.jpg'));
      await pumpDeck(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(tester.getSize(find.byType(NotificationCard)).width,
          closeTo(1184 * 0.56, 1));
      expect(tester.getCenter(find.byType(NotificationCard)).dx,
          closeTo(1184 / 2, 1));
    });

    testWidgets('a picture card uses the full width in portrait',
        (tester) async {
      service.ingest(_note(image: '/a.jpg'));
      await pumpDeck(tester, canvas: const Size(864, 1184));
      await tester.pump(const Duration(seconds: 2));
      expect(tester.getSize(find.byType(NotificationCard)).width,
          greaterThan(864 * 0.8));
    });

    testWidgets('a picture card uses the full width on a narrow landscape',
        (tester) async {
      service.ingest(_note(image: '/a.jpg', camera: 'front_door'));
      await pumpDeck(tester, canvas: const Size(720, 640));
      await tester.pump(const Duration(seconds: 2));
      expect(tester.getSize(find.byType(NotificationCard)).width,
          greaterThan(720 * 0.8));
    });

    testWidgets('a text card still uses the full width', (tester) async {
      service.ingest(_note());
      await pumpDeck(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(tester.getSize(find.byType(NotificationCard)).width,
          greaterThan(1184 * 0.8));
    });

    testWidgets('mute state survives an in-place update', (tester) async {
      service.ingest(_note(image: '/a.jpg'));
      await pumpDeck(tester);
      await tester.pump(const Duration(seconds: 2));
      await tester.tap(find.text('Mute'));
      await tester.pump();

      service.ingest(_note(image: '/a.jpg', title: 'Still there'));
      await tester.pump();

      expect(find.text('Still there'), findsOneWidget);
      expect(find.text('Unmute'), findsOneWidget);
    });

    testWidgets('in-place update does not replay the entrance', (tester) async {
      service.ingest(_note(image: '/a.jpg'));
      await pumpDeck(tester);
      await tester.pump(const Duration(seconds: 2));

      service.ingest(_note(image: '/a.jpg', title: 'Still there'));
      await tester.pump();

      final opacity = tester.widget<Opacity>(find
          .ancestor(
              of: find.byType(NotificationCard), matching: find.byType(Opacity))
          .first);
      expect(opacity.opacity, 1);
    });
  });
}
