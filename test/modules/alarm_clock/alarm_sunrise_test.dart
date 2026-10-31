import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/models/ha_entity.dart';
import 'package:hearth/modules/alarm_clock/alarm_audio.dart';
import 'package:hearth/modules/alarm_clock/alarm_models.dart';
import 'package:hearth/modules/alarm_clock/alarm_service.dart';
import 'package:hearth/modules/alarm_clock/sunrise_controller.dart';
import 'package:hearth/services/home_assistant_service.dart';

class _SilentAudio extends AlarmAudioPlayer {
  @override
  Future<void> play(String toneId, {double volume = 0.7}) async {}

  @override
  void stop() {}
}

/// Records each light call, with no Home Assistant behind it.
class _RecordingHa extends HomeAssistantService {
  final calls = <(String, String, Map<String, dynamic>)>[];

  @override
  void callService({
    required String domain,
    required String service,
    required String entityId,
    Map<String, dynamic>? data,
  }) {
    calls.add(('$domain.$service', entityId, data ?? const {}));
  }
}

void main() {
  late DateTime now;
  late _RecordingHa ha;
  late SunriseController sunrise;
  late AlarmService service;

  DateTime at(int hour, int minute, [int second = 0, int day = 5]) =>
      DateTime(2026, 11, day, hour, minute, second); // Nov 5 2026 is a Thursday.

  /// One check by each of the two tickers at the current time.
  void tick() {
    service.tickForTest();
    sunrise.tickForTest();
  }

  const dawn = Alarm(id: 'a', time: '07:00', sunriseDuration: 15);

  setUp(() {
    now = at(6, 30);
    ha = _RecordingHa();
    sunrise = SunriseController(clock: () => now, ha: () => ha);
    service = AlarmService(
      clock: () => now,
      audio: _SilentAudio(),
      sunrise: sunrise,
    );
  });

  tearDown(() {
    service.dispose();
    sunrise.dispose();
  });

  group('starting', () {
    test('waits until the configured minutes before the alarm', () {
      service.addAlarm(dawn);
      now = at(6, 44, 59);
      tick();
      expect(sunrise.active, isFalse);

      now = at(6, 45);
      tick();
      expect(sunrise.active, isTrue);
      expect(sunrise.progress, 0);
    });

    test('an alarm with the sunrise off never starts one', () {
      service.addAlarm(dawn.copyWith(sunriseDuration: 0));
      now = at(6, 59);
      tick();
      expect(sunrise.active, isFalse);
    });

    test('a turned-off alarm never starts one', () {
      service.addAlarm(dawn.copyWith(enabled: false));
      now = at(6, 59);
      tick();
      expect(sunrise.active, isFalse);
    });

    test('progress follows the clock, not how often it is checked', () {
      service.addAlarm(dawn);
      now = at(6, 52, 30);
      tick();
      expect(sunrise.progress, closeTo(0.5, 0.001));
    });

    test('a sunrise saved late joins partway through', () {
      now = at(6, 55);
      service.addAlarm(dawn);
      expect(sunrise.active, isTrue);
      expect(sunrise.progress, closeTo(10 / 15, 0.001));
    });

    test('picks up partway after Hearth restarts', () async {
      final dir = await Directory.systemTemp.createTemp('alarm_sunrise');
      addTearDown(() => dir.delete(recursive: true));
      await File('${dir.path}/alarms.json')
          .writeAsString(jsonEncode([dawn.toJson()]));
      final restarted = AlarmService(
        directory: () async => dir.path,
        clock: () => now,
        audio: _SilentAudio(),
        sunrise: sunrise,
      );
      addTearDown(restarted.dispose);

      now = at(6, 50);
      await restarted.load();

      expect(sunrise.active, isTrue);
      expect(sunrise.progress, closeTo(5 / 15, 0.001));
    });

    test('runs on each day of a repeating alarm and no other', () {
      service.addAlarm(dawn.copyWith(days: [4]));
      now = at(6, 50);
      tick();
      expect(sunrise.active, isTrue);

      now = at(7, 0, 5);
      tick();
      service.dismiss();

      now = at(6, 50, 0, 6); // Friday.
      tick();
      expect(sunrise.active, isFalse);

      now = at(6, 50, 0, 12); // The next Thursday.
      tick();
      expect(sunrise.active, isTrue);
    });

    test('an alarm just after midnight starts the evening before', () {
      service.addAlarm(dawn.copyWith(time: '00:05', days: [5])); // Friday.
      now = at(23, 55); // Thursday night.
      tick();
      expect(sunrise.active, isTrue);
      expect(sunrise.progress, closeTo(5 / 15, 0.001));
    });

    test('with two windows open, the alarm ringing soonest leads', () {
      service.addAlarm(dawn.copyWith(
          id: 'later', time: '07:10', sunriseDuration: 30, sunriseLights: ['light.later']));
      service.addAlarm(dawn.copyWith(sunriseLights: ['light.sooner']));
      now = at(6, 50);
      tick();
      expect(sunrise.progress, closeTo(5 / 15, 0.001));
      expect(ha.calls.map((c) => c.$2).toSet(), {'light.sooner'});
    });
  });

  group('ringing', () {
    test('holds at full while the alarm rings', () {
      service.addAlarm(dawn);
      now = at(7, 0, 3);
      tick();
      expect(service.firedAlarm?.id, 'a');
      expect(sunrise.active, isTrue);
      expect(sunrise.progress, 1);

      now = at(7, 20);
      tick();
      expect(sunrise.progress, 1);
    });

    test('an alarm that rings without a run-up goes straight to full', () {
      service.addAlarm(dawn);
      service.fireAlarmForTest(dawn);
      expect(sunrise.active, isTrue);
      expect(sunrise.progress, 1);
    });
  });

  group('snooze', () {
    setUp(() {
      service.addAlarm(dawn.copyWith(snoozeDuration: 10));
      now = at(7, 0, 3);
      tick();
    });

    test('drops back and climbs to full by the time it rings again', () {
      service.snooze();
      expect(sunrise.active, isTrue);
      expect(sunrise.progress, closeTo(0.3, 0.001));

      now = at(7, 5, 3);
      tick();
      expect(sunrise.progress, closeTo(0.65, 0.001));

      now = at(7, 10, 3);
      tick();
      expect(service.firedAlarm?.id, 'a');
      expect(sunrise.progress, 1);
    });

    test('dismissing after a snooze ends it', () {
      service.snooze();
      now = at(7, 10, 3);
      tick();
      service.dismiss();
      expect(sunrise.active, isFalse);
    });

    test('turning the sunrise off during a snooze ends it', () {
      service.snooze();
      service.updateAlarm(dawn.copyWith(sunriseDuration: 0));
      expect(sunrise.active, isFalse);
    });
  });

  group('ending', () {
    test('dismiss ends it', () {
      service.addAlarm(dawn);
      now = at(7, 0, 3);
      tick();
      service.dismiss();
      expect(sunrise.active, isFalse);
      expect(sunrise.progress, 0);
    });

    test('a one-time alarm does not start over after dismiss', () {
      service.addAlarm(dawn.copyWith(oneTime: true));
      now = at(7, 0, 3);
      tick();
      service.dismiss();
      now = at(7, 0, 10);
      tick();
      expect(sunrise.active, isFalse);
    });

    test('turning the alarm off in the window ends it', () {
      service.addAlarm(dawn);
      now = at(6, 50);
      tick();
      service.toggleEnabled('a');
      expect(sunrise.active, isFalse);
    });

    test('deleting the alarm in the window ends it', () {
      service.addAlarm(dawn);
      now = at(6, 50);
      tick();
      service.deleteAlarm('a');
      expect(sunrise.active, isFalse);
    });

    test('moving the alarm later in the window ends it for now', () {
      service.addAlarm(dawn);
      now = at(6, 50);
      tick();
      service.updateAlarm(dawn.copyWith(time: '08:00'));
      expect(sunrise.active, isFalse);

      now = at(7, 45);
      tick();
      expect(sunrise.active, isTrue);
      expect(sunrise.progress, 0);
    });

    test('a restore ends it', () async {
      service.addAlarm(dawn);
      now = at(6, 50);
      tick();
      await service.replaceAll(const []);
      expect(sunrise.active, isFalse);
    });

    test('turning the sunrise off while ringing ends it', () {
      service.addAlarm(dawn);
      now = at(7, 0, 3);
      tick();
      service.updateAlarm(dawn.copyWith(sunriseDuration: 0));
      expect(service.firedAlarm?.id, 'a');
      expect(sunrise.active, isFalse);
    });
  });

  group('lights', () {
    const lit = Alarm(
      id: 'a',
      time: '07:00',
      sunriseDuration: 15,
      sunriseLights: ['light.bedroom', 'light.hall'],
    );

    Map<String, dynamic> lastFor(String entityId) =>
        ha.calls.lastWhere((c) => c.$2 == entityId).$3;

    test('come on dim as it starts, without turning anything off', () {
      service.addAlarm(lit);
      now = at(6, 45);
      tick();

      expect(ha.calls.map((c) => c.$1).toSet(), {'light.turn_on'});
      expect(ha.calls.map((c) => c.$2).toSet(), {'light.bedroom', 'light.hall'});
      // Home Assistant treats brightness 0 as "turn off".
      expect(lastFor('light.bedroom')['brightness'], 1);
      expect(lastFor('light.bedroom')['color_temp_kelvin'], 2200);
    });

    test('use the field Home Assistant accepts for colour temperature', () {
      service.addAlarm(lit);
      now = at(6, 45);
      tick();
      expect(lastFor('light.bedroom').containsKey('color_temp'), isFalse);
    });

    test('update every 30 seconds, not every tick', () {
      service.addAlarm(lit.copyWith(sunriseLights: ['light.bedroom']));
      now = at(6, 45);
      tick();
      expect(ha.calls, hasLength(1));

      now = at(6, 45, 29);
      tick();
      expect(ha.calls, hasLength(1));

      // A late tick can't land on an exact multiple of 30 and must still send.
      now = at(6, 45, 31);
      tick();
      expect(ha.calls, hasLength(2));
    });

    test('climb slowly at first and reach full at the alarm', () {
      service.addAlarm(lit);
      now = at(6, 52, 30);
      tick();
      // Halfway through the time is a quarter of the way up the curve.
      expect(lastFor('light.bedroom')['brightness'], 64);
      expect(lastFor('light.bedroom')['color_temp_kelvin'], 2650);

      now = at(7, 0, 3);
      tick();
      expect(lastFor('light.bedroom')['brightness'], 255);
      expect(lastFor('light.bedroom')['color_temp_kelvin'], 4000);
    });

    test('are left alone once full', () {
      service.addAlarm(lit);
      now = at(7, 0, 3);
      tick();
      ha.calls.clear();

      now = at(7, 15);
      tick();
      expect(ha.calls, isEmpty);
    });

    test('dim to 30% warm on snooze and climb back', () {
      service.addAlarm(lit.copyWith(snoozeDuration: 10));
      now = at(7, 0, 3);
      tick();
      service.snooze();
      expect(lastFor('light.bedroom')['brightness'], 77);
      expect(lastFor('light.bedroom')['color_temp_kelvin'], 2200);

      now = at(7, 10, 3);
      tick();
      expect(lastFor('light.bedroom')['brightness'], 255);
    });

    test('stay as they are after dismiss', () {
      service.addAlarm(lit);
      now = at(7, 0, 3);
      tick();
      ha.calls.clear();

      service.dismiss();
      now = at(7, 1);
      tick();

      expect(ha.calls, isEmpty);
    });

    test('stay as they are if the alarm is turned off partway', () {
      service.addAlarm(lit);
      now = at(6, 50);
      tick();
      ha.calls.clear();

      service.toggleEnabled('a');
      now = at(6, 51);
      tick();

      expect(ha.calls, isEmpty);
    });

    test('stay on when the tone gives up and nobody came', () async {
      final s = AlarmService(
        clock: () => now,
        audio: _SilentAudio(),
        sunrise: sunrise,
        toneLimit: Duration.zero,
      );
      addTearDown(s.dispose);
      s.addAlarm(lit);
      now = at(7, 0, 3);
      s.tickForTest();
      sunrise.tickForTest();
      await Future<void>.delayed(Duration.zero); // Let the tone limit pass.
      ha.calls.clear();

      now = at(8, 0);
      s.tickForTest();
      sunrise.tickForTest();

      expect(s.firedAlarm?.id, 'a');
      expect(ha.calls, isEmpty);
    });

    test('an alarm without lights calls nothing', () {
      service.addAlarm(dawn);
      now = at(6, 50);
      tick();
      expect(ha.calls, isEmpty);
    });
  });

  group('screen', () {
    test('the tint fades in so the photos do not cut to dark', () {
      service.addAlarm(dawn);
      now = at(6, 45);
      tick();
      expect(sunrise.overlayAlpha, 0);

      now = at(6, 47, 15); // 15%.
      tick();
      expect(sunrise.overlayAlpha, closeTo(0.35, 0.001));

      now = at(6, 52, 30); // 50%.
      tick();
      expect(sunrise.overlayAlpha, closeTo(0.7, 0.001));
    });

    test('text stays readable on every colour of the ramp', () {
      double contrast(Color a, Color b) {
        final la = a.computeLuminance(), lb = b.computeLuminance();
        final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
        return (hi + 0.05) / (lo + 0.05);
      }

      service.addAlarm(dawn);
      for (var second = 0; second <= 900; second += 15) {
        now = at(6, 45).add(Duration(seconds: second));
        tick();
        final color = sunrise.currentColor;
        expect(contrast(color, SunriseController.inkOn(color)),
            greaterThanOrEqualTo(4.5),
            reason: 'at $second s, on $color');
      }
    });
  });

  group('HaEntity.isDimmable', () {
    HaEntity light(List<String>? modes) => HaEntity(
          entityId: 'light.x',
          state: 'off',
          attributes: {'supported_color_modes': ?modes},
          lastChanged: DateTime(2026),
        );

    test('anything with brightness is', () {
      expect(light(['brightness']).isDimmable, isTrue);
      expect(light(['color_temp', 'rgb']).isDimmable, isTrue);
    });

    test('on/off lights are not', () {
      expect(light(['onoff']).isDimmable, isFalse);
    });

    test('a light that reports no modes is not', () {
      expect(light(null).isDimmable, isFalse);
    });
  });
}
