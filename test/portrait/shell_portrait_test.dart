import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/app/current_screen_provider.dart';
import 'package:hearth/app/hub_shell.dart';
import 'package:hearth/app/page_indicator.dart';
import 'package:hearth/app/page_visibility.dart';
import 'package:hearth/app/screen_navigator.dart';
import 'package:hearth/config/hub_config.dart';
import 'package:hearth/config/webview_config.dart';
import 'package:hearth/models/hearth_notification.dart';
import 'package:hearth/modules/alarm_clock/sunrise_controller.dart';
import 'package:hearth/screens/home/home_screen.dart';
import 'package:hearth/services/music_assistant_service.dart';
import 'package:hearth/services/notification_service.dart';
import 'package:hearth/services/timer_service.dart';
import 'package:hearth/services/voice_assistant_service.dart';
import 'package:hearth/services/weather_service.dart';

import 'portrait_fixtures.dart';
import 'portrait_harness.dart';

const _staticModuleIds = [
  'alarm_clock',
  'media',
  'controls',
  'cameras',
  'protect',
  'mealie',
  'livetv',
];

final _webviews = [
  for (var i = 0; i < 4; i++)
    WebviewConfig(
      id: 'webview:custom:$i',
      url: 'https://example.com/$i',
      name: 'Energy Dashboard $i',
      iconCodePoint: Icons.dashboard.codePoint,
      source: WebviewSource.customUrl,
      order: i,
    ),
];

/// Every module in both trays: eleven tiles, more than one row holds on any
/// of the canvases. Nothing sits in the swipe row, so the PageView is just
/// Home and Settings and no module screen is built.
HubConfig _crowdedConfig({bool swapEdges = false}) => HubConfig(
      setupComplete: true,
      webviews: _webviews,
      modulePlacements: {
        for (final id in [..._staticModuleIds, ..._webviews.map((w) => w.id)])
          id: const ['menu1', 'menu2'],
      },
      topSwipeAction: swapEdges ? 'menu1' : 'menu2',
      bottomSwipeAction: swapEdges ? 'menu2' : 'menu1',
    );

/// The real HubShell over unconfigured services — none of them open a socket
/// without a URL — with Home populated and a voice response on screen.
Future<void> _pumpShell(
  WidgetTester tester, {
  HubConfig? config,
  NotificationService? notifications,
  VoiceAssistantState voice = const VoiceAssistantState(),
  SunriseController? sunrise,
}) async {
  final deck = notifications ?? silentNotifications();
  final timers = TimerService()
    ..attachNotificationService(deck)
    ..startTimer(const Duration(hours: 2, minutes: 15));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      hubConfigProvider.overrideWith(
          (ref) => MemoryConfigNotifier(config ?? _crowdedConfig())),
      notificationServiceProvider.overrideWith((ref) => deck),
      timerServiceProvider.overrideWith((ref) => timers),
      weatherStateProvider
          .overrideWith((ref) => Stream.value(sampleWeather())),
      maAllPlayersProvider
          .overrideWith((ref) => Stream.value(samplePlayers())),
      voiceAssistantStateProvider.overrideWith((ref) => Stream.value(voice)),
      if (sunrise != null)
        sunriseControllerProvider.overrideWith((ref) => sunrise),
    ],
    // The observer as HearthApp registers it, so pushed routes publish.
    child: Consumer(
      builder: (context, ref, _) => hostScreen(
        const HubShell(),
        navigatorObservers: [ref.watch(pageRouteObserverProvider)],
      ),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _swipeFromEdge(
  WidgetTester tester,
  Size canvas, {
  required bool top,
}) async {
  await tester.flingFrom(
    Offset(canvas.width / 2, top ? 20 : canvas.height - 20),
    Offset(0, top ? 200 : -200),
    1500,
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testLayouts('HubShell tints the photos during a sunrise',
      (tester, canvas) async {
    final sunrise = SunriseController();
    final past = DateTime.now().subtract(const Duration(minutes: 1));
    sunrise.run(alarmId: 'a1', start: past, end: past);
    await _pumpShell(tester, sunrise: sunrise);

    final tint = sunrise.currentColor.withValues(alpha: sunrise.overlayAlpha);
    final layer = find.byWidgetPredicate(
        (w) => w is Container && w.color == tint);
    expect(layer, findsOneWidget);
    expect(tester.getSize(layer), canvas);
    expect(find.byType(HomeScreen), findsOneWidget);
    await unmount(tester);
  });

  testLayouts('HubShell tracks an edge-menu module route',
      (tester, canvas) async {
    await _pumpShell(tester);
    final container = ProviderScope.containerOf(
        tester.element(find.byType(HubShell)));
    expect(container.read(currentPageProvider), 'home');
    await _swipeFromEdge(tester, canvas, top: false);
    await tester.tap(find.text('Controls'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(container.read(currentPageProvider), 'route:controls');
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(container.read(currentPageProvider), 'home');
    await unmount(tester);
  });

  testLayoutsAndSplitHalves('HubShell tracks the timer pushed from Home',
      (tester, canvas) async {
    await _pumpShell(tester, config: const HubConfig(setupComplete: true));
    final container = ProviderScope.containerOf(
        tester.element(find.byType(HubShell)));
    // Wake the shell so Home's pill can be tapped.
    await tester.tapAt(canvas.center(Offset.zero));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.descendant(
        of: find.byType(HomeScreen), matching: find.byIcon(Icons.timer)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(container.read(currentPageProvider), 'route:timer');
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(container.read(currentPageProvider), 'home');
    await unmount(tester);
  });

  testLayouts('HubShell shows a screen the navigator asks for',
      (tester, canvas) async {
    await _pumpShell(tester);
    final container = ProviderScope.containerOf(
        tester.element(find.byType(HubShell)));
    // A module open from the tray: the request pops it to reach the page.
    await _swipeFromEdge(tester, canvas, top: false);
    await tester.tap(find.text('Controls'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(container.read(currentPageProvider), 'route:controls');
    container.read(screenNavigatorProvider).show('settings');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(container.read(currentPageProvider), 'settings');
    expect(container.read(currentScreenProvider).id, 'settings');
    await unmount(tester);
  });

  testLayouts('HubShell on Home with the page indicator',
      (tester, canvas) async {
    await _pumpShell(tester, config: const HubConfig(setupComplete: true));
    await tester.tapAt(canvas.center(Offset.zero));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(PageIndicator), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsOneWidget);
    await unmount(tester);
  });

  testLayouts('HubShell bottom tray with eleven modules',
      (tester, canvas) async {
    await _pumpShell(tester);
    await _swipeFromEdge(tester, canvas, top: false);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Energy Dashboard 3'), findsOneWidget);
    // Every tile stays on screen where it can be tapped.
    for (final label in ['Settings', 'Energy Dashboard 3']) {
      final rect = tester.getRect(find.text(label));
      expect((Offset.zero & canvas).contains(rect.topLeft), isTrue);
      expect((Offset.zero & canvas).contains(rect.bottomRight), isTrue);
    }
    await unmount(tester);
  });

  testLayouts('HubShell top tray with volume and eleven modules',
      (tester, canvas) async {
    await _pumpShell(tester);
    await _swipeFromEdge(tester, canvas, top: true);
    expect(find.text('Volume'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
    final rect = tester.getRect(find.text('Energy Dashboard 3'));
    expect((Offset.zero & canvas).contains(rect.topLeft), isTrue);
    expect((Offset.zero & canvas).contains(rect.bottomRight), isTrue);
    await unmount(tester);
  });

  testLayouts('HubShell trays on swapped edges', (tester, canvas) async {
    await _pumpShell(tester, config: _crowdedConfig(swapEdges: true));
    await _swipeFromEdge(tester, canvas, top: true);
    expect(find.text('Settings'), findsOneWidget);
    // Tapping outside the tray closes it.
    await tester.tapAt(Offset(canvas.width / 2, canvas.height - 10));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Settings'), findsNothing);
    await _swipeFromEdge(tester, canvas, top: false);
    expect(find.text('Volume'), findsOneWidget);
    await unmount(tester);
  });

  testLayoutsAndSplitHalves(
      'HubShell with a toast, a voice response and notifications',
      (tester, canvas) async {
    final deck = silentNotifications()
      ..ingest(sampleNotification(0))
      ..ingest(sampleNotification(1, priority: NotificationPriority.alert));
    await _pumpShell(
      tester,
      config: const HubConfig(setupComplete: true),
      notifications: deck,
      voice: const VoiceAssistantState(
        state: VoiceState.responding,
        responseText: 'The garage door has been open for forty five minutes '
            'and the temperature outside is twenty eight degrees, so I have '
            'closed it and turned the porch light on for you.',
      ),
    );
    // Two cards fill Hearth's half of a split screen and cover the mic toggle,
    // so clear them there first.
    final cramped = canvas.height < 800;
    if (cramped) {
      for (final n in deck.notifications.toList()) {
        deck.dismiss(n.id);
      }
      await tester.pump(const Duration(milliseconds: 400));
    }
    // The mic toggle raises a toast.
    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Microphone muted'), findsOneWidget);
    expect(find.byType(Dismissible), findsNWidgets(cramped ? 0 : 2));
    await unmount(tester);
    // Past the toast's own dismiss timer.
    await tester.pump(const Duration(seconds: 4));
  });
}
