import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/modules/alarm_clock/alarm_audio.dart';
import 'package:hearth/modules/alarm_clock/alarm_models.dart';
import 'package:hearth/modules/alarm_clock/alarm_service.dart';

/// Records what the service asks for, with no audio behind it.
class _FakeAudio extends AlarmAudioPlayer {
  final played = <(String, double)>[];
  int stops = 0;

  @override
  Future<void> play(String toneId, {double volume = 0.7}) async {
    played.add((toneId, volume));
  }

  @override
  void stop() => stops++;
}

void main() {
  late DateTime now;
  late _FakeAudio audio;
  late AlarmService service;

  DateTime at(int hour, int minute, [int second = 0, int day = 5]) =>
      DateTime(2026, 11, day, hour, minute, second); // Nov 5 2026 is a Thursday.

  setUp(() {
    now = at(6, 59);
    audio = _FakeAudio();
    service = AlarmService(clock: () => now, audio: audio);
  });

  tearDown(() => service.dispose());

  group('firing', () {
    test('fires when the check lands after the alarm time', () {
      service.addAlarm(const Alarm(id: 'a', time: '07:00'));
      now = at(7, 0, 20);
      service.tickForTest();
      expect(service.firedAlarm?.id, 'a');
    });

    test('does not fire before its time', () {
      service.addAlarm(const Alarm(id: 'a', time: '07:00'));
      now = at(6, 59, 59);
      service.tickForTest();
      expect(service.firedAlarm, isNull);
    });

    test('does not fire when over a minute late', () {
      service.addAlarm(const Alarm(id: 'a', time: '07:00'));
      now = at(7, 1, 1);
      service.tickForTest();
      expect(service.firedAlarm, isNull);
    });

    test('a disabled alarm does not fire', () {
      service.addAlarm(const Alarm(id: 'a', time: '07:00', enabled: false));
      now = at(7, 0, 5);
      service.tickForTest();
      expect(service.firedAlarm, isNull);
    });

    test('fires once per occurrence', () {
      service.addAlarm(const Alarm(id: 'a', time: '07:00', days: [4]));
      now = at(7, 0, 5);
      service.tickForTest();
      service.dismiss();
      now = at(7, 0, 10);
      service.tickForTest();
      expect(service.firedAlarm, isNull);
    });

    test('a repeating alarm fires again on its next day', () {
      service.addAlarm(const Alarm(id: 'a', time: '07:00', days: [4, 5]));
      now = at(7, 0, 5);
      service.tickForTest();
      service.dismiss();

      now = at(7, 0, 5, 6); // Friday.
      service.tickForTest();

      expect(service.firedAlarm?.id, 'a');
    });

    test('a repeating alarm skips days it is not set for', () {
      service.addAlarm(const Alarm(id: 'a', time: '07:00', days: [4]));
      now = at(7, 0, 5, 6); // Friday.
      service.tickForTest();
      expect(service.firedAlarm, isNull);
    });

    test('two alarms at the same time both ring in turn', () {
      service.addAlarm(const Alarm(id: 'a', time: '07:00'));
      service.addAlarm(const Alarm(id: 'b', time: '07:00'));
      now = at(7, 0, 5);
      service.tickForTest();
      final first = service.firedAlarm?.id;
      service.dismiss();

      now = at(7, 0, 10);
      service.tickForTest();

      expect(first, 'a');
      expect(service.firedAlarm?.id, 'b');
    });

    test('adding an alarm for a time that just passed does not ring', () {
      now = at(7, 0, 30);
      service.addAlarm(const Alarm(id: 'a', time: '07:00'));
      now = at(7, 0, 35);
      service.tickForTest();
      expect(service.firedAlarm, isNull);
    });

    test('editing an alarm to a time that just passed does not ring', () {
      service.addAlarm(const Alarm(id: 'a', time: '08:00'));
      now = at(7, 0, 30);
      service.updateAlarm(const Alarm(id: 'a', time: '07:00'));
      now = at(7, 0, 35);
      service.tickForTest();
      expect(service.firedAlarm, isNull);
    });

    test('turning on an alarm whose time just passed does not ring', () {
      service.addAlarm(const Alarm(id: 'a', time: '07:00', enabled: false));
      now = at(7, 0, 30);
      service.toggleEnabled('a');
      now = at(7, 0, 35);
      service.tickForTest();
      expect(service.firedAlarm, isNull);
    });

    test('restoring alarms whose time just passed does not ring', () async {
      now = at(7, 0, 30);
      await service.replaceAll(const [Alarm(id: 'a', time: '07:00')]);
      now = at(7, 0, 35);
      service.tickForTest();
      expect(service.firedAlarm, isNull);
    });
  });

  group('snooze', () {
    setUp(() {
      service.addAlarm(
          const Alarm(id: 'a', time: '07:00', snoozeDuration: 10, days: [4]));
      now = at(7, 0, 5);
      service.tickForTest();
      service.snooze();
    });

    test('rings again when the snooze ends', () {
      now = at(7, 10, 6);
      service.tickForTest();
      expect(service.firedAlarm?.id, 'a');
      expect(service.snoozedUntil, isNull);
    });

    test('stays quiet until the snooze ends', () {
      now = at(7, 10, 4);
      service.tickForTest();
      expect(service.firedAlarm, isNull);
      expect(service.snoozedUntil, isNotNull);
    });

    test('can be snoozed again', () {
      now = at(7, 10, 6);
      service.tickForTest();
      service.snooze();
      now = at(7, 20, 7);
      service.tickForTest();
      expect(service.firedAlarm?.id, 'a');
    });

    test('a deleted alarm does not come back', () {
      service.deleteAlarm('a');
      now = at(7, 10, 6);
      service.tickForTest();
      expect(service.firedAlarm, isNull);
      expect(service.snoozedUntil, isNull);
    });

    test('a turned-off alarm does not come back', () {
      service.toggleEnabled('a');
      now = at(7, 10, 6);
      service.tickForTest();
      expect(service.firedAlarm, isNull);
      expect(service.snoozedUntil, isNull);
    });

    test('waits for another ringing alarm before coming back', () {
      service.addAlarm(const Alarm(id: 'b', time: '07:09'));
      now = at(7, 9, 5);
      service.tickForTest();
      expect(service.firedAlarm?.id, 'b');

      now = at(7, 10, 6);
      service.tickForTest();
      expect(service.firedAlarm?.id, 'b');

      service.dismiss();
      service.tickForTest();
      expect(service.firedAlarm?.id, 'a');
    });

  });

  group('several alarms', () {
    test('both snoozed alarms come back', () {
      service.addAlarm(const Alarm(id: 'a', time: '06:50', snoozeDuration: 10));
      service.addAlarm(const Alarm(id: 'b', time: '06:55', snoozeDuration: 10));
      now = at(6, 50, 5);
      service.addAlarm(const Alarm(id: 'unrelated', time: '12:00'));
      service.tickForTest();
      expect(service.firedAlarm?.id, 'a');
      service.snooze();

      now = at(6, 55, 5);
      service.tickForTest();
      expect(service.firedAlarm?.id, 'b');
      service.snooze();

      now = at(7, 0, 6);
      service.tickForTest();
      expect(service.firedAlarm?.id, 'a');
      service.dismiss();

      now = at(7, 5, 6);
      service.tickForTest();
      expect(service.firedAlarm?.id, 'b');
    });

    test('snoozedUntil is the earliest snooze', () {
      service.addAlarm(const Alarm(id: 'a', time: '07:00', snoozeDuration: 30));
      service.addAlarm(const Alarm(id: 'b', time: '07:00', snoozeDuration: 5));
      now = at(7, 0, 5);
      service.tickForTest();
      service.snooze();
      service.tickForTest();
      service.snooze();
      expect(service.snoozedUntil, at(7, 5, 5));
    });

    test('an alarm due while another rings is not lost', () {
      service.addAlarm(const Alarm(id: 'a', time: '07:00'));
      service.addAlarm(const Alarm(id: 'b', time: '07:01'));
      now = at(7, 0, 5);
      service.tickForTest();
      expect(service.firedAlarm?.id, 'a');

      now = at(7, 1, 5);
      service.tickForTest();
      expect(service.firedAlarm?.id, 'a', reason: 'the first keeps ringing');

      now = at(7, 15);
      service.dismiss();
      service.tickForTest();
      expect(service.firedAlarm?.id, 'b');
    });

    test('a waiting alarm that gets deleted does not ring', () {
      service.addAlarm(const Alarm(id: 'a', time: '07:00'));
      service.addAlarm(const Alarm(id: 'b', time: '07:00'));
      now = at(7, 0, 5);
      service.tickForTest();
      service.tickForTest();
      service.deleteAlarm('b');
      service.dismiss();
      service.tickForTest();
      expect(service.firedAlarm, isNull);
    });

    test('a waiting alarm that gets turned off does not ring', () {
      service.addAlarm(const Alarm(id: 'a', time: '07:00'));
      service.addAlarm(const Alarm(id: 'b', time: '07:00'));
      now = at(7, 0, 5);
      service.tickForTest();
      service.tickForTest();
      service.toggleEnabled('b');
      service.dismiss();
      service.tickForTest();
      expect(service.firedAlarm, isNull);
    });

    final unattendedAudio = _FakeAudio();

    Future<AlarmService> unattended(List<Alarm> alarms) async {
      unattendedAudio.played.clear();
      final s = AlarmService(
        clock: () => now,
        audio: unattendedAudio,
        toneLimit: const Duration(milliseconds: 5),
      );
      addTearDown(s.dispose);
      alarms.forEach(s.addAlarm);
      now = at(7, 0, 5);
      s.tickForTest();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      return s;
    }

    test('an alarm left on screen does not block the next day', () async {
      final s = await unattended(
          [const Alarm(id: 'a', time: '07:00', days: [4, 5])]);
      expect(s.firedAlarm?.id, 'a');

      now = at(7, 0, 5, 6);
      s.tickForTest();

      expect(s.firedAlarm?.id, 'a');
      expect(unattendedAudio.played, hasLength(2));
    });

    test('a later alarm takes over once the first has gone quiet', () async {
      final s = await unattended([
        const Alarm(id: 'a', time: '07:00'),
        const Alarm(id: 'b', time: '07:40'),
      ]);
      now = at(7, 40, 5);
      s.tickForTest();

      expect(s.firedAlarm?.id, 'b');
      expect(s.alarms.firstWhere((x) => x.id == 'a').enabled, isFalse,
          reason: 'taken over counts as dismissed');
    });

    test('a silent alarm also gives way after the limit', () async {
      final s = await unattended([
        const Alarm(id: 'a', time: '07:00', soundType: 'none'),
        const Alarm(id: 'b', time: '07:40'),
      ]);
      now = at(7, 40, 5);
      s.tickForTest();
      expect(s.firedAlarm?.id, 'b');
    });
  });

  group('editing a ringing alarm', () {
    setUp(() {
      service.addAlarm(const Alarm(id: 'a', time: '07:00', soundId: 'birds'));
      now = at(7, 0, 5);
      service.tickForTest();
    });

    test('turning it off stops it', () {
      final stops = audio.stops;
      service.updateAlarm(
          const Alarm(id: 'a', time: '07:00', soundId: 'birds', enabled: false));
      expect(service.firedAlarm, isNull);
      expect(audio.stops, stops + 1);
    });

    test('changing the sound restarts it', () {
      service.updateAlarm(const Alarm(id: 'a', time: '07:00', soundId: 'classic'));
      expect(service.firedAlarm?.soundId, 'classic');
      expect(audio.played.last, ('classic', 0.7));
    });

    test('changing the volume restarts it', () {
      service.updateAlarm(
          const Alarm(id: 'a', time: '07:00', soundId: 'birds', volume: 0.2));
      expect(audio.played.last, ('birds', 0.2));
    });

    test('changing the label leaves the tone alone', () {
      final played = audio.played.length;
      service.updateAlarm(
          const Alarm(id: 'a', time: '07:00', soundId: 'birds', label: 'Hi'));
      expect(service.firedAlarm?.label, 'Hi');
      expect(audio.played, hasLength(played));
    });

    test('setting it to no sound silences it', () {
      final stops = audio.stops;
      service.updateAlarm(
          const Alarm(id: 'a', time: '07:00', soundType: 'none'));
      expect(service.firedAlarm?.id, 'a');
      expect(audio.stops, greaterThan(stops));
    });

    test('turning off a snoozed alarm cancels the snooze', () {
      service.snooze();
      service.updateAlarm(
          const Alarm(id: 'a', time: '07:00', enabled: false));
      expect(service.snoozedUntil, isNull);
    });
  });

  group('sound', () {
    test('plays the chosen tone at the chosen volume', () {
      service.addAlarm(const Alarm(
          id: 'a', time: '07:00', soundId: 'birds', volume: 0.4));
      now = at(7, 0, 5);
      service.tickForTest();
      expect(audio.played, [('birds', 0.4)]);
    });

    test('an alarm set to no sound stays silent', () {
      service.addAlarm(
          const Alarm(id: 'a', time: '07:00', soundType: 'none'));
      now = at(7, 0, 5);
      service.tickForTest();
      expect(service.firedAlarm?.id, 'a');
      expect(audio.played, isEmpty);
    });

    test('stops on dismiss', () {
      service.addAlarm(const Alarm(id: 'a', time: '07:00'));
      now = at(7, 0, 5);
      service.tickForTest();
      final before = audio.stops;
      service.dismiss();
      expect(audio.stops, before + 1);
    });

    test('stops on snooze and plays again when it ends', () {
      service.addAlarm(const Alarm(id: 'a', time: '07:00', days: [4]));
      now = at(7, 0, 5);
      service.tickForTest();
      final before = audio.stops;

      service.snooze();
      expect(audio.stops, before + 1);

      now = at(7, 10, 6);
      service.tickForTest();
      expect(audio.played, hasLength(2));
    });

    test('stops when the ringing alarm is deleted', () {
      service.addAlarm(const Alarm(id: 'a', time: '07:00'));
      now = at(7, 0, 5);
      service.tickForTest();
      final before = audio.stops;
      service.deleteAlarm('a');
      expect(service.firedAlarm, isNull);
      expect(audio.stops, before + 1);
    });

    test('stops on dispose', () {
      final other = _FakeAudio();
      final s = AlarmService(clock: () => now, audio: other);
      s.addAlarm(const Alarm(id: 'a', time: '07:00'));
      now = at(7, 0, 5);
      s.tickForTest();
      s.dispose();
      expect(other.stops, greaterThan(0));
    });

    test('the tone stops at its limit and the alarm stays up', () async {
      final other = _FakeAudio();
      final s = AlarmService(
        clock: () => now,
        audio: other,
        toneLimit: const Duration(milliseconds: 20),
      );
      addTearDown(s.dispose);
      s.addAlarm(const Alarm(id: 'a', time: '07:00'));
      now = at(7, 0, 5);
      s.tickForTest();
      final before = other.stops;

      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(other.stops, before + 1);
      expect(s.firedAlarm?.id, 'a');
    });

    test('the default limit is 30 minutes', () {
      expect(kAlarmToneLimit, const Duration(minutes: 30));
    });
  });
}
