import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/config/hub_config.dart';
import 'package:hearth/models/hearth_notification.dart';
import 'package:hearth/modules/alarm_clock/alarm_alert_overlay.dart';
import 'package:hearth/modules/alarm_clock/alarm_models.dart';
import 'package:hearth/modules/alarm_clock/alarm_service.dart';
import 'package:hearth/modules/alarm_clock/sunrise_controller.dart';
import 'package:hearth/modules/cameras/camera_feed_overlay.dart';
import 'package:hearth/modules/cameras/frigate_service.dart';
import 'package:hearth/modules/livetv/live_tv_overlay.dart';
import 'package:hearth/services/dlna/dlna_cast_overlay.dart';
import 'package:hearth/services/dlna/dlna_renderer_state.dart';
import 'package:hearth/services/dlna/dlna_service.dart';
import 'package:hearth/services/notification_image_loader.dart';
import 'package:hearth/services/notification_service.dart';
import 'package:hearth/services/plex/livetv/plex_livetv_service.dart';
import 'package:hearth/services/plex/livetv/plex_livetv_state.dart';
import 'package:hearth/services/plex/livetv/plex_livetv_wire.dart';
import 'package:hearth/services/plex/plex_cast_overlay.dart';
import 'package:hearth/services/plex/plex_player_state.dart';
import 'package:hearth/services/plex/plex_service.dart';
import 'package:hearth/services/video/hearth_video_player.dart';
import 'package:hearth/widgets/notification_deck_overlay.dart';
import 'package:hearth/widgets/notification_picture.dart';

import 'module_support.dart' show FakeHomeAssistant;
import 'portrait_fixtures.dart';
import 'portrait_harness.dart';

/// An alarm that is ringing, without the audio and ticker the real service
/// starts when it fires one.
class _RingingAlarmService extends AlarmService {
  _RingingAlarmService(this._fired);

  final Alarm _fired;

  @override
  Alarm? get firedAlarm => _fired;
}

/// A 4:3 frame, the shape many doorbells produce, with no network behind it.
class _FixedPictureLoader extends NotificationImageLoader {
  _FixedPictureLoader() : super(haUrl: '', haToken: '');

  @override
  Future<Uint8List?> fetch(String image) async => base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAEElEQVR4nGNwCEiAIwacHADaBwtBoHgf+wAAAABJRU5ErkJggg==');
}

/// A stream that never starts, so the feed stays on its placeholder.
class _PendingPlayer implements HearthVideoPlayer {
  @override
  ValueListenable<Size?> get videoSize => ValueNotifier<Size?>(null);

  @override
  Future<bool> play(String url) => Completer<bool>().future;

  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HealthyFrigate extends FrigateService {
  _HealthyFrigate()
      : super(baseUrl: 'http://frigate.invalid', ha: FakeHomeAssistant());

  @override
  Future<double?> getCameraFps(String cameraName) async => 15;
}

/// Hosts a layer-5 overlay the way HubShell does: a direct child of a
/// full-screen Stack. The cast services run unconfigured, so they own no
/// player and the overlays show their loading state in place of video.
Future<void> _pumpOverlay(
  WidgetTester tester,
  Widget overlay, {
  List<Override> overrides = const [],
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      hubConfigProvider.overrideWith((ref) => MemoryConfigNotifier()),
      ...overrides,
    ],
    child: hostScreen(Stack(children: [overlay])),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  group('Notification deck', () {
    testLayoutsAndSplitHalves('three long cards, one an alert', (tester, canvas) async {
      final service = silentNotifications()
        ..ingest(sampleNotification(0))
        ..ingest(sampleNotification(1, priority: NotificationPriority.alert))
        ..ingest(sampleNotification(2));
      await _pumpOverlay(
        tester,
        NotificationDeckOverlay(onWake: () {}),
        overrides: [notificationServiceProvider.overrideWith((ref) => service)],
      );
      expect(find.byType(Dismissible), findsNWidgets(3));
      await unmount(tester);
    });

    testLayoutsAndSplitHalves('a camera card above two text cards',
        (tester, canvas) async {
      final service = silentNotifications()
        ..ingest(sampleCameraNotification())
        ..ingest(sampleNotification(0))
        ..ingest(sampleNotification(1));
      await _pumpOverlay(
        tester,
        NotificationDeckOverlay(onWake: () {}),
        overrides: [
          notificationServiceProvider.overrideWith((ref) => service),
          notificationImageLoaderProvider
              .overrideWithValue(_FixedPictureLoader()),
        ],
      );
      expect(find.byType(NotificationPicture), findsOneWidget);
      expect(find.byType(Dismissible), findsNWidgets(3));
      await unmount(tester);
    });

    testLayoutsAndSplitHalves('a camera card on its own stays on screen',
        (tester, canvas) async {
      final service = silentNotifications()..ingest(sampleCameraNotification());
      await _pumpOverlay(
        tester,
        NotificationDeckOverlay(onWake: () {}),
        overrides: [
          notificationServiceProvider.overrideWith((ref) => service),
          notificationImageLoaderProvider
              .overrideWithValue(_FixedPictureLoader()),
        ],
      );
      final picture = tester.getRect(find.byType(NotificationPicture));
      final close = tester.getRect(find.byIcon(Icons.close));
      expect(picture.top, greaterThanOrEqualTo(0));
      expect(close.bottom, lessThanOrEqualTo(canvas.height));
      await unmount(tester);
    });
  });

  group('Camera feed', () {
    testLayouts('open with a long camera name', (tester, canvas) async {
      registerVideoPlayerFactory(mediaKit: _PendingPlayer.new);
      await _pumpOverlay(
        tester,
        CameraFeedOverlay(onWake: () {}),
        overrides: [
          hubConfigProvider.overrideWith((ref) => MemoryConfigNotifier(
              const HubConfig(frigateUrl: 'http://frigate.invalid:5000'))),
          cameraFeedProvider.overrideWith((ref) => CameraFeedController()
            ..open('back_yard_north_fence_overview_ptz_with_a_very_long_name')),
          frigateServiceProvider.overrideWith((ref) => _HealthyFrigate()),
          dlnaRendererStateProvider
              .overrideWith((ref) => const Stream<DlnaRendererState>.empty()),
          plexPlayerStateProvider
              .overrideWith((ref) => const Stream<PlexPlayerState>.empty()),
          plexLiveTvStateProvider
              .overrideWith((ref) => const Stream<PlexLiveTvState>.empty()),
        ],
      );
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      await unmount(tester);
    });
  });

  group('Alarm alert', () {
    testLayoutsAndSplitHalves('ringing alarm with a long label', (tester, canvas) async {
      await _pumpOverlay(
        tester,
        AlarmAlertOverlay(onWake: () {}),
        overrides: [
          alarmServiceProvider.overrideWith((ref) => _RingingAlarmService(
                const Alarm(
                  id: 'a1',
                  time: '06:30',
                  label: 'Wake up — school run, then the dentist at half past '
                      'eight, and remember the bins go out today',
                ),
              )),
        ],
      );
      expect(find.text('Dismiss'), findsOneWidget);
      expect(find.text('Tap anywhere to snooze'), findsOneWidget);
      await unmount(tester);
    });

    testLayoutsAndSplitHalves('ringing at the end of a sunrise', (tester, canvas) async {
      final sunrise = SunriseController();
      final past = DateTime.now().subtract(const Duration(minutes: 1));
      sunrise.run(alarmId: 'a1', start: past, end: past);
      await _pumpOverlay(
        tester,
        AlarmAlertOverlay(onWake: () {}),
        overrides: [
          sunriseControllerProvider.overrideWith((ref) => sunrise),
          alarmServiceProvider.overrideWith((ref) => _RingingAlarmService(
                const Alarm(id: 'a1', time: '06:30', label: 'Wake up'),
              )),
        ],
      );
      // Dark ink on the pale gold, where the white it uses on black can't be read.
      Color? colorOf(String text) =>
          tester.widget<Text>(find.text(text)).style?.color;
      expect(colorOf('Dismiss'), Colors.black);
      expect(colorOf('Wake up')?.withValues(alpha: 1), Colors.black);
      await unmount(tester);
    });
  });

  group('DLNA cast', () {
    testLayouts('playing with the transport bar revealed',
        (tester, canvas) async {
      await _pumpOverlay(
        tester,
        DlnaCastOverlay(onWake: () {}),
        overrides: [
          dlnaRendererStateProvider.overrideWith((ref) => Stream.value(
                const DlnaRendererState(
                  transportState: DlnaTransportState.playing,
                  currentUri: 'http://nas.local/video.mp4',
                  position: Duration(hours: 11, minutes: 12, seconds: 13),
                  duration: Duration(hours: 12, minutes: 34, seconds: 56),
                ),
              )),
        ],
      );
      await tester.tapAt(canvas.center(Offset.zero));
      await tester.pump();
      expect(find.text('Stop'), findsOneWidget);
      expect(find.text('11:12:13 / 12:34:56'), findsOneWidget);
      await unmount(tester);
    });
  });

  group('Plex cast', () {
    PlexPlayerState playing({
      Duration position = const Duration(hours: 1, minutes: 2, seconds: 3),
      int introEndMs = 0,
      int creditsEndMs = 0,
    }) =>
        PlexPlayerState(
          transportState: PlexTransportState.playing,
          currentUri: 'http://pms.local/transcode/start.m3u8',
          title: longTitle,
          position: position,
          duration: const Duration(hours: 12, minutes: 34, seconds: 56),
          hasNext: true,
          hasPrev: true,
          introEndMs: introEndMs,
          creditsEndMs: creditsEndMs,
        );

    testLayouts('transport bar with queue controls and Skip Intro',
        (tester, canvas) async {
      await _pumpOverlay(
        tester,
        PlexCastOverlay(onWake: () {}),
        overrides: [
          plexPlayerStateProvider.overrideWith((ref) => Stream.value(playing(
                position: const Duration(seconds: 30),
                introEndMs: 90000,
              ))),
        ],
      );
      await tester.tapAt(canvas.center(Offset.zero));
      await tester.pump();
      expect(find.text('Stop'), findsOneWidget);
      expect(find.text('Skip Intro'), findsOneWidget);
      expect(find.byIcon(Icons.skip_previous), findsOneWidget);
      await unmount(tester);
    });

    testLayouts('Next Episode prompt during credits', (tester, canvas) async {
      await _pumpOverlay(
        tester,
        PlexCastOverlay(onWake: () {}),
        overrides: [
          plexPlayerStateProvider.overrideWith((ref) => Stream.value(playing(
                position: const Duration(hours: 12, minutes: 30),
                creditsEndMs: 45296000,
              ))),
        ],
      );
      await tester.tapAt(canvas.center(Offset.zero));
      await tester.pump();
      expect(find.text('Next Episode'), findsOneWidget);
      await unmount(tester);
    });
  });

  group('Live TV overlay', () {
    const channel = PlexChannel(
      channelKey: 'c1',
      number: '1045.12',
      callSign: 'KELODT-HD Sioux Falls CBS Affiliate West',
    );

    Future<void> pumpLiveTv(WidgetTester tester, PlexLiveTvState state) =>
        _pumpOverlay(
          tester,
          LiveTvOverlay(onWake: () {}),
          overrides: [
            plexLiveTvStateProvider.overrideWith((ref) => Stream.value(state)),
          ],
        );

    testLayouts('tuning a channel with a long call sign',
        (tester, canvas) async {
      await pumpLiveTv(
        tester,
        const PlexLiveTvState(
          channels: [channel],
          currentChannel: channel,
          phase: LiveTvPhase.tuning,
          resolved: true,
        ),
      );
      expect(find.text('LIVE'), findsOneWidget);
      expect(find.byIcon(Icons.stop), findsOneWidget);
      await unmount(tester);
    });

    testLayouts('playing', (tester, canvas) async {
      await pumpLiveTv(
        tester,
        const PlexLiveTvState(
          channels: [channel],
          currentChannel: channel,
          phase: LiveTvPhase.playing,
          resolved: true,
        ),
      );
      expect(find.byIcon(Icons.skip_next), findsOneWidget);
      await unmount(tester);
    });

    testLayouts('a long playback error', (tester, canvas) async {
      await pumpLiveTv(
        tester,
        const PlexLiveTvState(
          channels: [channel],
          currentChannel: channel,
          phase: LiveTvPhase.error,
          error: 'The tuner could not lock onto this channel: all tuners are '
              'in use by recordings, or the antenna signal is too weak to '
              'decode. Try another channel or stop a recording.',
          resolved: true,
        ),
      );
      expect(find.byIcon(Icons.stop), findsOneWidget);
      await unmount(tester);
    });
  });
}
