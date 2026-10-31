import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/models/ha_entity.dart';
import 'package:hearth/modules/alarm_clock/alarm_editor_screen.dart';
import 'package:hearth/modules/alarm_clock/alarm_models.dart';
import 'package:hearth/modules/alarm_clock/alarm_service.dart';
import 'package:hearth/services/home_assistant_service.dart';

import 'module_support.dart';
import 'portrait_harness.dart';

/// Holds a fixed alarm list; nothing is read from or written to disk.
class _FixedAlarms extends AlarmService {
  _FixedAlarms(this._fixed);
  final List<Alarm> _fixed;

  @override
  List<Alarm> get alarms => _fixed;

  @override
  (Alarm, DateTime)? get nextAlarm => _fixed.isEmpty
      ? null
      : (_fixed.first, DateTime.now().add(const Duration(hours: 9, minutes: 5)));

  @override
  void toggleEnabled(String id) {}

  @override
  void deleteAlarm(String id) {}
}

const _alarms = [
  Alarm(id: 'a1', time: '06:15', label: 'Weekday wake-up', days: [1, 2, 3, 4, 5]),
  Alarm(id: 'a2', time: '07:30', label: kLongName, days: [1, 3, 5, 6]),
  Alarm(id: 'a3', time: '08:45', days: [6, 7], enabled: false),
  Alarm(id: 'a4', time: '12:00', label: 'Lunch', days: [1, 2, 3, 4, 5, 6, 7]),
  Alarm(id: 'a5', time: '17:20', label: 'School run', oneTime: true),
  Alarm(id: 'a6', time: '21:55', label: 'Wind down', days: [7], sunriseDuration: 0),
  Alarm(id: 'a7', time: '23:10', label: 'Take bins out', days: [2]),
];

HaEntity _light(String id, String name) => HaEntity(
      entityId: id,
      state: 'off',
      attributes: {
        'friendly_name': name,
        'supported_color_modes': ['brightness'],
      },
      lastChanged: DateTime(2026),
    );

void main() {
  Widget screen() => staticModule('alarm_clock').buildScreen(isActive: true);

  testLayouts('alarm list with no alarms', (tester, canvas) async {
    await pumpModule(tester, screen(), overrides: [
      alarmServiceProvider.overrideWith((ref) => _FixedAlarms(const [])),
    ]);
    expect(find.text('No alarms'), findsOneWidget);
  });

  testLayouts('alarm list with seven alarms', (tester, canvas) async {
    await pumpModule(tester, screen(), overrides: [
      alarmServiceProvider.overrideWith((ref) => _FixedAlarms(_alarms)),
    ]);
    expect(find.text('06:15'), findsOneWidget);
    // The add button stays on the canvas and clear of its edge.
    final fab = tester.getRect(find.byType(FloatingActionButton));
    expect(fab.right, lessThanOrEqualTo(canvas.width));
    expect(fab.bottom, lessThanOrEqualTo(canvas.height));
  });

  testLayouts('alarm editor opened on an existing alarm', (tester, canvas) async {
    await pumpModule(tester, screen(), overrides: [
      alarmServiceProvider.overrideWith((ref) => _FixedAlarms(_alarms)),
    ]);
    await tester.tap(find.text('07:30'));
    await tester.pumpAndSettle();
    expect(find.text('Edit Alarm'), findsOneWidget);

    // Every section is reachable by scrolling, down to the actions.
    await tester.scrollUntilVisible(find.text('Delete'), 200,
        scrollable: find.byType(Scrollable).first);
    final save = tester.getRect(find.text('Save'));
    expect(save.right, lessThanOrEqualTo(canvas.width));
    expect(save.bottom, lessThanOrEqualTo(canvas.height));
  });

  testLayouts('alarm editor for a new alarm with sunrise on',
      (tester, canvas) async {
    await pumpModule(tester, const AlarmEditorScreen(), overrides: [
      alarmServiceProvider.overrideWith((ref) => _FixedAlarms(const [])),
    ]);
    expect(find.text('New Alarm'), findsOneWidget);
    // A new alarm starts with sunrise off; turning it on adds the chip row.
    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(find.text('Duration'), findsOneWidget);
    // All seven day toggles sit inside the canvas.
    for (final label in ['M', 'W', 'F']) {
      final r = tester.getRect(find.text(label));
      expect(r.left, greaterThanOrEqualTo(0));
      expect(r.right, lessThanOrEqualTo(canvas.width));
    }
  });

  testLayouts('alarm editor with many sunrise lights to pick',
      (tester, canvas) async {
    await pumpModule(
      tester,
      const AlarmEditorScreen(
        alarm: Alarm(
          id: 'a1',
          time: '06:15',
          sunriseDuration: 15,
          sunriseLights: ['light.l0'],
        ),
      ),
      overrides: [
        alarmServiceProvider.overrideWith((ref) => _FixedAlarms(const [])),
        homeAssistantServiceProvider.overrideWith((ref) => FakeHomeAssistant([
              _light('light.long', kLongName),
              for (var i = 0; i < 20; i++) _light('light.l$i', 'Lamp $i'),
            ])),
      ],
    );
    final long = find.text(kLongName);
    await tester.ensureVisible(long);
    await tester.pump();
    final r = tester.getRect(long);
    expect(r.left, greaterThanOrEqualTo(0));
    expect(r.right, lessThanOrEqualTo(canvas.width));
    // The picker doesn't push the actions off the end of the scroll.
    await tester.scrollUntilVisible(find.text('Save'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(tester.getRect(find.text('Save')).bottom,
        lessThanOrEqualTo(canvas.height));
  });
}
