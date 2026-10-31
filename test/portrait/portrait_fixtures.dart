import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/config/hub_config.dart';
import 'package:hearth/models/hearth_notification.dart';
import 'package:hearth/models/music_state.dart';
import 'package:hearth/models/weather_state.dart';
import 'package:hearth/services/notification_service.dart';

/// Config held in memory so nothing in a layout test touches disk.
class MemoryConfigNotifier extends HubConfigNotifier {
  MemoryConfigNotifier([HubConfig config = const HubConfig()]) {
    state = config;
  }

  @override
  Future<void> update(HubConfig Function(HubConfig) updater) async {
    state = updater(state);
  }
}

/// A full forecast: 24 hourly entries and 8 days, the most the screens show.
WeatherState sampleWeather([String cond = 'partlycloudy']) => WeatherState(
      condition: cond,
      temperature: 102,
      humidity: 100,
      windSpeed: 38,
      hourlyForecast: List.generate(
        24,
        (i) => HourlyForecast(
          time: DateTime(2026, 4, 24, i),
          temperature: 95 + (i % 9).toDouble(),
          condition: cond,
        ),
      ),
      dailyForecast: List.generate(
        8,
        (i) => DailyForecast(
          date: DateTime(2026, 4, 24).add(Duration(days: i)),
          high: 100 + i.toDouble(),
          low: 78 + i.toDouble(),
          condition: cond,
          precipitation: 12.5 * i,
          windSpeed: 28.0 + i,
        ),
      ),
    );

const longTitle =
    'Symphony No. 9 in D minor, Op. 125 "Choral": IV. Finale — Ode to Joy '
    '(Remastered 2019 Deluxe Anniversary Edition)';

/// Two zones with a track each, so the pill shows its player chevrons.
Map<String, MusicPlayerState> samplePlayers() => {
      for (final zone in ['Kitchen and Dining Room Speakers', 'Office'])
        zone: MusicPlayerState(
          playbackState: PlaybackState.playing,
          activeZoneId: zone,
          activeZoneName: zone,
          currentTrack: const MusicTrack(
            title: longTitle,
            artist: 'Berliner Philharmoniker & Herbert von Karajan',
            album: 'Beethoven: The Nine Symphonies',
            duration: Duration(minutes: 24),
          ),
        ),
    };

/// A notification service that never shells out for a chime.
NotificationService silentNotifications() =>
    NotificationService(playChime: (_) async {});

HearthNotification sampleNotification(
  int i, {
  NotificationPriority priority = NotificationPriority.info,
}) =>
    HearthNotification(
      id: 'n$i',
      source: NotificationSource.values[i % NotificationSource.values.length],
      sourceLabel: 'HOME ASSISTANT AUTOMATION',
      priority: priority,
      title: 'Garage door has been left open for longer than thirty minutes',
      body: 'The side garage door sensor still reports open. Someone may have '
          'forgotten to close it after taking the bins out, and the outside '
          'temperature is dropping below freezing tonight.',
      sticky: true,
      timestamp: DateTime(2026, 4, 24, 21, 5),
    );

HearthNotification sampleCameraNotification() => HearthNotification(
      id: 'tag-door',
      tag: 'door',
      source: NotificationSource.frigate,
      sourceLabel: 'FRIGATE',
      priority: NotificationPriority.info,
      title: 'Person Detected at Back Yard North Fence Overview',
      body: '',
      sticky: true,
      timestamp: DateTime(2026, 4, 24, 21, 5),
      image: '/api/camera_proxy/camera.back_yard_north_fence',
      imageRefresh: const Duration(seconds: 3),
      camera: 'back_yard_north_fence',
    );

/// Unmounts the tree so periodic timers and tickers owned by widgets and
/// providers are cancelled before the test ends.
Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}
