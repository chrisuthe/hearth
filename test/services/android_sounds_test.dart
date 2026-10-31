import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/models/hearth_notification.dart';
import 'package:hearth/modules/alarm_clock/alarm_audio.dart';
import 'package:hearth/services/android_sounds.dart';
import 'package:hearth/services/notification_service.dart';
import 'package:hearth/services/timer_service.dart';

const _channel = MethodChannel('com.hearth/sounds');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;
  Object? failWith;

  Iterable<MethodCall> named(String method) =>
      calls.where((c) => c.method == method);

  setUp(() {
    calls = [];
    failWith = null;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      if (failWith != null) throw failWith!;
      return null;
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  HearthNotification note(NotificationPriority priority, {bool muted = false}) =>
      HearthNotification(
        id: 'n',
        source: NotificationSource.ha,
        sourceLabel: 'HOME ASST',
        priority: priority,
        title: 'x',
        body: '',
        sticky: true,
        muted: muted,
        timestamp: DateTime(2026, 11, 5),
      );

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 150));

  group('notification chimes', () {
    late NotificationService service;

    setUp(() => service = NotificationService());
    tearDown(() => service.dispose());

    test('Soft Ping is one gentle tone, as on the Pi', () async {
      service.ingest(note(NotificationPriority.info));
      await settle();
      expect(named('playTone').map((c) => c.arguments), [
        {'hz': 740, 'durationMs': 510, 'volume': 0.16},
      ]);
    });

    test('Ember Alert is three urgent tones, as on the Pi', () async {
      service.ingest(note(NotificationPriority.alert));
      await settle();
      expect(named('playTone').map((c) => c.arguments), [
        {'hz': 880, 'durationMs': 162, 'volume': 0.35},
        {'hz': 1174, 'durationMs': 162, 'volume': 0.35},
        {'hz': 880, 'durationMs': 162, 'volume': 0.35},
      ]);
    });

    test('a muted card stays silent', () async {
      service.ingest(note(NotificationPriority.info, muted: true));
      await settle();
      expect(calls, isEmpty);
    });

    test('night mode stays silent', () async {
      final night = NotificationService(isChimeSuppressed: () => true);
      addTearDown(night.dispose);
      night.ingest(note(NotificationPriority.info));
      await settle();
      expect(calls, isEmpty);
    });

    test('a player failure does not reach the caller', () async {
      failWith = PlatformException(code: 'audio');
      service.ingest(note(NotificationPriority.info));
      await settle();
      expect(service.notifications, hasLength(1));
    });
  });

  group('timer beep', () {
    test('loops until the timer is dismissed', () async {
      final timers = TimerService();
      addTearDown(timers.dispose);
      timers.startTimer(const Duration(milliseconds: 1));

      await Future<void>.delayed(const Duration(milliseconds: 1000));
      final beeps = named('playTone').length;
      expect(beeps, greaterThanOrEqualTo(2));
      expect(named('playTone').first.arguments,
          {'hz': 880, 'durationMs': 464, 'volume': 0.5});

      timers.dismissAllFired();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final after = named('playTone').length;
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(named('playTone').length, after);
    });

    test('a failing player does not spin', () async {
      failWith = PlatformException(code: 'audio');
      final timers = TimerService();
      addTearDown(timers.dispose);
      timers.startTimer(const Duration(milliseconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      expect(named('playTone').length, lessThan(5));
    });

    test('the satellite ring still takes priority', () async {
      final timers = TimerService();
      addTearDown(timers.dispose);
      timers.attachRing(start: () async => true, stop: () async {});
      timers.startTimer(const Duration(milliseconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(named('playTone'), isEmpty);
    });
  });

  group('alarm tones', () {
    late AlarmAudioPlayer player;

    setUp(() => player = AlarmAudioPlayer());

    test('play starts the bundled tone at the alarm volume', () async {
      await player.play('birds', volume: 0.4);
      expect(named('startAlarmTone').single.arguments,
          {'asset': 'assets/alarm_tones/birds.ogg', 'volume': 0.4});
    });

    test('every builtin tone has a bundled asset path', () async {
      for (final id in AlarmAudioPlayer.builtinTones.keys) {
        await player.play(id);
      }
      expect(named('startAlarmTone').map((c) => c.arguments['asset']), [
        for (final id in AlarmAudioPlayer.builtinTones.keys)
          'assets/alarm_tones/$id.ogg',
      ]);
    });

    test('an unknown tone falls back to the default rather than silence',
        () async {
      await player.play('../../secrets');
      expect(named('startAlarmTone').single.arguments['asset'],
          'assets/alarm_tones/gentle_morning.ogg');
    });

    test('stop stops the tone', () async {
      await player.play('classic');
      player.stop();
      await settle();
      expect(named('stopAlarmTone'), hasLength(1));
    });

    test('a player failure does not reach the caller', () async {
      failWith = PlatformException(code: 'audio');
      await player.play('classic');
      player.stop();
      await settle();
      expect(calls, isNotEmpty);
    });
  });

  group('AndroidSounds', () {
    test('a missing native side returns quietly', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
      await AndroidSounds.playTone(440, const Duration(milliseconds: 10), 0.5);
      await AndroidSounds.startAlarmTone('classic', 0.5);
      await AndroidSounds.stopAlarmTone();
    });
  });
}
