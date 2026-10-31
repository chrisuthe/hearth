import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/modules/alarm_clock/alarm_models.dart';

void main() {
  group('Alarm JSON serialization', () {
    test('round-trips through JSON', () {
      const alarm = Alarm(
        id: 'test1',
        time: '06:30',
        days: [1, 2, 3, 4, 5],
        label: 'Work',
        sunriseDuration: 20,
        sunriseLights: ['light.bedroom', 'light.hallway'],
        soundType: 'music_assistant',
        soundId: 'playlist_123',
        snoozeDuration: 5,
        volume: 0.9,
      );
      final json = alarm.toJson();
      final restored = Alarm.fromJson(json);
      expect(restored.id, 'test1');
      expect(restored.time, '06:30');
      expect(restored.days, [1, 2, 3, 4, 5]);
      expect(restored.label, 'Work');
      expect(restored.enabled, true);
      expect(restored.oneTime, false);
      expect(restored.sunriseDuration, 20);
      expect(restored.sunriseLights, ['light.bedroom', 'light.hallway']);
      expect(restored.soundType, 'music_assistant');
      expect(restored.soundId, 'playlist_123');
      expect(restored.snoozeDuration, 5);
      expect(restored.volume, 0.9);
    });

    test('fromJson uses defaults for missing fields', () {
      final alarm = Alarm.fromJson({'id': 'x', 'time': '08:00'});
      expect(alarm.label, '');
      expect(alarm.enabled, true);
      expect(alarm.days, isEmpty);
      expect(alarm.oneTime, false);
      expect(alarm.sunriseDuration, 0);
      expect(alarm.sunriseLights, isEmpty);
      expect(alarm.soundType, 'builtin');
      expect(alarm.soundId, 'gentle_morning');
      expect(alarm.snoozeDuration, 10);
      expect(alarm.volume, 0.7);
    });

    test('fromJson generates id when missing', () {
      final alarm = Alarm.fromJson({'time': '09:00'});
      expect(alarm.id, isNotEmpty);
      expect(alarm.id.length, 6);
    });

    test('fromJson handles volume as int', () {
      final alarm = Alarm.fromJson({'id': 'v', 'time': '07:00', 'volume': 1});
      expect(alarm.volume, 1.0);
    });
  });

  group('Alarm copyWith', () {
    test('creates modified copy', () {
      const alarm = Alarm(id: 'a', time: '07:00', label: 'Morning');
      final copy = alarm.copyWith(time: '08:00', label: 'Late');
      expect(copy.id, 'a');
      expect(copy.time, '08:00');
      expect(copy.label, 'Late');
    });

    test('preserves unchanged fields', () {
      const alarm = Alarm(
        id: 'a',
        time: '07:00',
        days: [1, 3, 5],
        volume: 0.5,
      );
      final copy = alarm.copyWith(enabled: false);
      expect(copy.days, [1, 3, 5]);
      expect(copy.volume, 0.5);
      expect(copy.enabled, false);
    });
  });

  group('Alarm hour/minute getters', () {
    test('parses time correctly', () {
      const alarm = Alarm(id: 'a', time: '14:05');
      expect(alarm.hour, 14);
      expect(alarm.minute, 5);
    });

    test('parses midnight', () {
      const alarm = Alarm(id: 'a', time: '00:00');
      expect(alarm.hour, 0);
      expect(alarm.minute, 0);
    });
  });

  group('Alarm.nextFireTime', () {
    test('returns null when disabled', () {
      const alarm = Alarm(id: 'a', time: '07:00', enabled: false);
      final now = DateTime(2026, 4, 12, 6, 0);
      expect(alarm.nextFireTime(now), isNull);
    });

    test('one-time alarm today if time is in the future', () {
      const alarm = Alarm(id: 'a', time: '14:00');
      final now = DateTime(2026, 4, 12, 10, 0); // 10am, before 2pm
      final next = alarm.nextFireTime(now)!;
      expect(next.day, 12);
      expect(next.hour, 14);
      expect(next.minute, 0);
    });

    test('one-time alarm tomorrow if time has passed', () {
      const alarm = Alarm(id: 'a', time: '06:00');
      final now = DateTime(2026, 4, 12, 10, 0); // 10am, past 6am
      final next = alarm.nextFireTime(now)!;
      expect(next.day, 13);
      expect(next.hour, 6);
    });

    test('one-time alarm tomorrow if time is exactly now', () {
      const alarm = Alarm(id: 'a', time: '10:00');
      final now = DateTime(2026, 4, 12, 10, 0);
      final next = alarm.nextFireTime(now)!;
      expect(next.day, 13);
      expect(next.hour, 10);
    });

    test('recurring finds today if day matches and time is future', () {
      // April 12, 2026 is a Sunday (weekday 7)
      const alarm = Alarm(id: 'a', time: '14:00', days: [7]);
      final now = DateTime(2026, 4, 12, 10, 0);
      final next = alarm.nextFireTime(now)!;
      expect(next.day, 12);
      expect(next.weekday, 7);
      expect(next.hour, 14);
    });

    test('recurring skips today if day matches but time has passed', () {
      // April 12, 2026 is a Sunday (weekday 7)
      const alarm = Alarm(id: 'a', time: '06:00', days: [7]);
      final now = DateTime(2026, 4, 12, 10, 0);
      final next = alarm.nextFireTime(now)!;
      // Next Sunday is April 19
      expect(next.day, 19);
      expect(next.weekday, 7);
    });

    test('recurring finds next weekday from Saturday evening', () {
      // April 11, 2026 is a Saturday (weekday 6)
      const alarm = Alarm(id: 'a', time: '07:00', days: [1, 2, 3, 4, 5]);
      final now = DateTime(2026, 4, 11, 20, 0);
      final next = alarm.nextFireTime(now)!;
      expect(next.weekday, 1); // Monday
      expect(next.day, 13);
      expect(next.hour, 7);
    });

    test('recurring finds tomorrow for daily alarm after time', () {
      const alarm =
          Alarm(id: 'a', time: '06:00', days: [1, 2, 3, 4, 5, 6, 7]);
      final now = DateTime(2026, 4, 12, 10, 0);
      final next = alarm.nextFireTime(now)!;
      expect(next.day, 13);
      expect(next.hour, 6);
    });

    test('recurring finds today for daily alarm before time', () {
      const alarm =
          Alarm(id: 'a', time: '14:00', days: [1, 2, 3, 4, 5, 6, 7]);
      final now = DateTime(2026, 4, 12, 10, 0);
      final next = alarm.nextFireTime(now)!;
      expect(next.day, 12);
      expect(next.hour, 14);
    });
  });

  group('Alarm.daySummary', () {
    test('shows "One time" for empty days with oneTime flag', () {
      const alarm = Alarm(id: 'a', time: '07:00', oneTime: true);
      expect(alarm.daySummary, 'One time');
    });

    test('shows "Tomorrow" for empty days without oneTime flag', () {
      const alarm = Alarm(id: 'a', time: '07:00');
      expect(alarm.daySummary, 'Tomorrow');
    });

    test('shows "Every day" for all 7 days', () {
      const alarm =
          Alarm(id: 'a', time: '07:00', days: [1, 2, 3, 4, 5, 6, 7]);
      expect(alarm.daySummary, 'Every day');
    });

    test('shows "Weekdays" for Mon-Fri', () {
      const alarm = Alarm(id: 'a', time: '07:00', days: [1, 2, 3, 4, 5]);
      expect(alarm.daySummary, 'Weekdays');
    });

    test('shows "Weekends" for Sat-Sun', () {
      const alarm = Alarm(id: 'a', time: '09:00', days: [6, 7]);
      expect(alarm.daySummary, 'Weekends');
    });

    test('shows individual day names for arbitrary days', () {
      const alarm = Alarm(id: 'a', time: '07:00', days: [1, 3, 5]);
      expect(alarm.daySummary, 'Mon, Wed, Fri');
    });

    test('shows single day name', () {
      const alarm = Alarm(id: 'a', time: '07:00', days: [2]);
      expect(alarm.daySummary, 'Tue');
    });

    test('does not match Weekdays if extra day present', () {
      const alarm = Alarm(id: 'a', time: '07:00', days: [1, 2, 3, 4, 5, 6]);
      expect(alarm.daySummary, isNot('Weekdays'));
      expect(alarm.daySummary, 'Mon, Tue, Wed, Thu, Fri, Sat');
    });
  });
}
