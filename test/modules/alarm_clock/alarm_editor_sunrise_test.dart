import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/models/ha_entity.dart';
import 'package:hearth/modules/alarm_clock/alarm_editor_screen.dart';
import 'package:hearth/modules/alarm_clock/alarm_models.dart';
import 'package:hearth/services/home_assistant_service.dart';

import '../../portrait/module_support.dart';

HaEntity _light(String id, String name, [String mode = 'brightness']) =>
    HaEntity(
      entityId: id,
      state: 'off',
      attributes: {
        'friendly_name': name,
        'supported_color_modes': [mode],
      },
      lastChanged: DateTime(2026),
    );

void main() {
  /// Opens the editor on [alarm], does [change], saves, and returns the result.
  Future<Alarm?> edit(
    WidgetTester tester,
    Alarm alarm, {
    Future<void> Function()? change,
  }) async {
    tester.view.physicalSize = const Size(1184, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Alarm? saved;
    await pumpModule(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            saved = await Navigator.of(context).push<Alarm>(MaterialPageRoute(
              builder: (_) => AlarmEditorScreen(alarm: alarm),
            ));
          },
          child: const Text('open'),
        ),
      ),
      overrides: [
        homeAssistantServiceProvider.overrideWith((ref) => FakeHomeAssistant([
              _light('light.bed', 'Bedside'),
              _light('light.hall', 'Hall'),
              _light('light.switch', 'Lamp Switch', 'onoff'),
            ])),
      ],
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await change?.call();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    return saved;
  }

  const lit = Alarm(
    id: 'a',
    time: '07:00',
    sunriseDuration: 20,
    sunriseLights: ['light.bed'],
  );

  testWidgets('saving keeps the lights already picked', (tester) async {
    final saved = await edit(tester, lit);
    expect(saved?.sunriseLights, ['light.bed']);
    expect(saved?.sunriseDuration, 20);
  });

  testWidgets('picking and unpicking changes what is saved', (tester) async {
    final saved = await edit(tester, lit, change: () async {
      await tester.tap(find.text('Hall'));
      await tester.tap(find.text('Bedside'));
      await tester.pump();
    });
    expect(saved?.sunriseLights, ['light.hall']);
  });

  testWidgets('on/off lights are not offered', (tester) async {
    await edit(tester, lit, change: () async {
      expect(find.text('Bedside'), findsOneWidget);
      expect(find.text('Lamp Switch'), findsNothing);
    });
  });

  testWidgets('a picked light Home Assistant no longer offers can be unpicked',
      (tester) async {
    final saved = await edit(
      tester,
      lit.copyWith(sunriseLights: ['light.gone', 'light.switch']),
      change: () async {
        await tester.tap(find.text('light.gone'));
        await tester.tap(find.text('Lamp Switch'));
        await tester.pump();
      },
    );
    expect(saved?.sunriseLights, isEmpty);
  });

  testWidgets('turning the sunrise on for an alarm saved without one sticks',
      (tester) async {
    final saved = await edit(
      tester,
      const Alarm(id: 'a', time: '07:00', sunriseDuration: 0),
      change: () async {
        await tester.tap(find.byType(Switch));
        await tester.pump();
      },
    );
    expect(saved?.sunriseDuration, 15);
  });
}
