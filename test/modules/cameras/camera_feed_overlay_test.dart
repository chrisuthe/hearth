import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/app/idle_controller.dart';
import 'package:hearth/config/hub_config.dart';
import 'package:hearth/models/frigate_event.dart';
import 'package:hearth/modules/cameras/camera_feed_overlay.dart';
import 'package:hearth/modules/cameras/cameras_screen.dart';
import 'package:hearth/modules/cameras/frigate_service.dart';
import 'package:hearth/services/dlna/dlna_renderer_state.dart';
import 'package:hearth/services/dlna/dlna_service.dart';
import 'package:hearth/services/plex/livetv/plex_livetv_service.dart';
import 'package:hearth/services/plex/livetv/plex_livetv_state.dart';
import 'package:hearth/services/plex/plex_player_state.dart';
import 'package:hearth/services/plex/plex_service.dart';
import 'package:hearth/services/toast_service.dart';
import 'package:hearth/services/video/hearth_video_player.dart';

import '../../portrait/module_support.dart';
import '../../portrait/portrait_harness.dart';

final Uint8List _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x60, 0x60, 0x60, 0xF8,
  0x0F, 0x00, 0x01, 0x04, 0x01, 0x00, 0x5F, 0xE5, 0xC3, 0x4B, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

const _videoKey = Key('fake-video');

class _FakePlayer implements HearthVideoPlayer {
  final size = ValueNotifier<Size?>(null);
  final playResult = Completer<bool>();
  final urls = <String>[];
  var disposeCount = 0;

  @override
  ValueListenable<Size?> get videoSize => size;

  @override
  Future<bool> play(String url) {
    urls.add(url);
    return playResult.future;
  }

  @override
  Widget buildView({BoxFit fit = BoxFit.contain}) =>
      const SizedBox.expand(key: _videoKey);

  @override
  void dispose() => disposeCount++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Frigate extends FrigateService {
  _Frigate({this.fps = 15, this.fixed = const []})
      : super(baseUrl: 'http://frigate.local:5000', ha: FakeHomeAssistant());

  final double? fps;
  final List<FrigateCamera> fixed;

  @override
  List<FrigateCamera> get cameras => fixed;

  @override
  Future<double?> getCameraFps(String cameraName) async => fps;
}

void main() {
  late List<_FakePlayer> players;
  late StreamController<PlexPlayerState> plex;

  setUp(() {
    players = [];
    plex = StreamController<PlexPlayerState>.broadcast();
    registerVideoPlayerFactory(mediaKit: () {
      final player = _FakePlayer();
      players.add(player);
      return player;
    });
  });
  tearDown(() => plex.close());

  ProviderContainer makeContainer({
    String frigateUrl = 'http://frigate.local:5000',
    double? fps = 15,
    List<FrigateCamera> cameras = const [],
  }) =>
      ProviderContainer(overrides: [
        hubConfigProvider.overrideWith((ref) =>
            MemoryConfigNotifier(HubConfig(frigateUrl: frigateUrl))),
        frigateServiceProvider
            .overrideWith((ref) => _Frigate(fps: fps, fixed: cameras)),
        plexPlayerStateProvider.overrideWith((ref) => plex.stream),
        dlnaRendererStateProvider
            .overrideWith((ref) => const Stream<DlnaRendererState>.empty()),
        plexLiveTvStateProvider
            .overrideWith((ref) => const Stream<PlexLiveTvState>.empty()),
      ]);

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    ProviderContainer? container,
    Widget? behind,
  }) async {
    final c = container ?? makeContainer();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: hostScreen(Stack(fit: StackFit.expand, children: [
        if (behind != null) Positioned.fill(child: behind),
        CameraFeedOverlay(onWake: () {}),
      ])),
    ));
    return c;
  }

  Future<void> finish(WidgetTester tester, ProviderContainer c) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
    c.dispose();
  }

  CameraFeedController feed(ProviderContainer c) =>
      c.read(cameraFeedProvider.notifier);

  testWidgets('renders nothing and creates no player until opened',
      (tester) async {
    final c = await pump(tester);
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(players, isEmpty);
    await finish(tester, c);
  });

  testWidgets('plays the Frigate RTSP stream for the camera', (tester) async {
    final c = await pump(tester);
    feed(c).open('front_door');
    await tester.pump();
    await tester.pump();
    expect(players.single.urls, ['rtsp://frigate.local:8554/front_door']);
    await finish(tester, c);
  });

  testWidgets('shows the supplied frame before video appears', (tester) async {
    final c = await pump(tester);
    feed(c).open('front_door', frame: _png);
    await tester.pump();
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(find.byKey(_videoKey), findsNothing);
    await finish(tester, c);
  });

  testWidgets('shows video once videoSize is known', (tester) async {
    final c = await pump(tester);
    feed(c).open('front_door', frame: _png);
    await tester.pump();
    await tester.pump();
    players.single.playResult.complete(true);
    players.single.size.value = const Size(1920, 1080);
    await tester.pump();
    expect(find.byKey(_videoKey), findsOneWidget);
    await finish(tester, c);
  });

  testWidgets('tap closes, disposes the player and unsuppresses idle',
      (tester) async {
    final c = await pump(tester);
    feed(c).open('front_door', frame: _png);
    await tester.pump();
    await tester.pump();
    expect(c.read(idleControllerProvider).isSuppressed, isTrue);

    await tester.tap(find.byType(CameraFeedOverlay));
    await tester.pump();
    await tester.pump();

    expect(c.read(cameraFeedProvider), isNull);
    expect(players.single.disposeCount, 1);
    expect(c.read(idleControllerProvider).isSuppressed, isFalse);
    await finish(tester, c);
  });

  testWidgets('stays open past 4 minutes 59', (tester) async {
    final c = await pump(tester);
    feed(c).open('front_door');
    await tester.pump();
    await tester.pump();
    players.single.playResult.complete(true);
    await tester.pump(const Duration(minutes: 4, seconds: 59));
    expect(c.read(cameraFeedProvider), isNotNull);
    await finish(tester, c);
  });

  testWidgets('closes after 5 minutes', (tester) async {
    final c = await pump(tester);
    feed(c).open('front_door');
    await tester.pump();
    await tester.pump();
    players.single.playResult.complete(true);
    await tester.pump(const Duration(minutes: 5));
    await tester.pump();
    expect(c.read(cameraFeedProvider), isNull);
    expect(players.single.disposeCount, 1);
    await finish(tester, c);
  });

  testWidgets('play returning false closes and shows a toast', (tester) async {
    final c = await pump(tester);
    feed(c).open('front_door');
    await tester.pump();
    await tester.pump();
    players.single.playResult.complete(false);
    await tester.pump();
    await tester.pump();
    expect(c.read(cameraFeedProvider), isNull);
    expect(c.read(toastProvider)?.message, 'front_door stream unavailable');
    await finish(tester, c);
  });

  testWidgets('no frigateUrl closes and shows a toast', (tester) async {
    final c = await pump(tester, container: makeContainer(frigateUrl: ''));
    feed(c).open('front_door');
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(c.read(cameraFeedProvider), isNull);
    expect(c.read(toastProvider)?.message, 'front_door stream unavailable');
    await finish(tester, c);
  });

  testWidgets('a stalled camera closes and shows a toast', (tester) async {
    final c = await pump(tester, container: makeContainer(fps: 0));
    feed(c).open('front_door');
    await tester.pump();
    await tester.pump();
    players.single.playResult.complete(true);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 3));
    }
    await tester.pump();
    expect(c.read(cameraFeedProvider), isNull);
    expect(c.read(toastProvider)?.message, 'front_door stream offline');
    await finish(tester, c);
  });

  testWidgets('closing during play() leaves no toast and disposes once',
      (tester) async {
    final c = await pump(tester);
    feed(c).open('front_door');
    await tester.pump();
    await tester.pump();

    feed(c).close();
    await tester.pump();
    players.single.playResult.complete(false);
    await tester.pump();
    await tester.pump();

    expect(c.read(toastProvider), isNull);
    expect(players.single.disposeCount, 1);
    await finish(tester, c);
  });

  testWidgets('a starting Plex cast closes the feed', (tester) async {
    final c = await pump(tester);
    feed(c).open('front_door');
    await tester.pump();
    await tester.pump();

    plex.add(const PlexPlayerState(
      transportState: PlexTransportState.playing,
      currentUri: 'http://pms.local/start.m3u8',
    ));
    await tester.pump();
    await tester.pump();

    expect(c.read(cameraFeedProvider), isNull);
    expect(players.single.disposeCount, 1);
    await finish(tester, c);
  });

  testWidgets('open is ignored while a feed is open', (tester) async {
    final c = await pump(tester);
    feed(c).open('front_door');
    await tester.pump();
    await tester.pump();

    feed(c).open('back_yard');
    await tester.pump();
    await tester.pump();

    expect(c.read(cameraFeedProvider)?.camera, 'front_door');
    expect(players, hasLength(1));
    await finish(tester, c);
  });

  testWidgets('opening a feed collapses an expanded camera and leaves idle suppressed',
      (tester) async {
    final camera =
        FrigateCamera.fromEntry('back_yard', 'http://frigate.local:5000');
    final c = await pump(
      tester,
      container: makeContainer(cameras: [camera]),
      behind: const CamerasScreen(isActive: true),
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.play_circle_outline));
    await tester.pump();
    expect(players, hasLength(1));
    final screenPlayer = players.single;

    feed(c).open('front_door');
    await tester.pump();
    await tester.pump();

    expect(screenPlayer.disposeCount, 1);
    expect(players, hasLength(2));
    expect(players.last.disposeCount, 0);
    expect(c.read(idleControllerProvider).isSuppressed, isTrue);
    await finish(tester, c);
  });
}
