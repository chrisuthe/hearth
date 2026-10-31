import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/config/hub_config.dart';
import 'package:hearth/modules/alarm_clock/alarm_models.dart';
import 'package:hearth/models/ha_entity.dart';
import 'package:hearth/modules/alarm_clock/alarm_service.dart';
import 'package:hearth/services/home_assistant_service.dart';
import 'package:hearth/plugins/alarm_clock/alarm_clock_plugin.dart';
import 'package:hearth/services/display_mode_service.dart';
import 'package:hearth/services/local_api_server.dart';

/// Exercises the Alarm Clock plugin's web routes end-to-end through
/// [LocalApiServer]: the browser-facing add / edit / delete path that backs the
/// web portal. Alarms live in [AlarmService] (not HubConfig), so the web-parity
/// drift-guard doesn't cover them — these tests do.
/// Offers fixed entities, with no Home Assistant behind them.
class FakeHomeAssistant extends HomeAssistantService {
  FakeHomeAssistant(List<HaEntity> entities)
      : _fixed = {for (final e in entities) e.entityId: e};

  final Map<String, HaEntity> _fixed;

  @override
  Map<String, HaEntity> get entities => _fixed;
}

void main() {
  group('Alarm Clock plugin routes', () {
    late ProviderContainer container;
    late DisplayModeService displayService;
    late HubConfigNotifier configNotifier;
    late AlarmService alarmService;
    late LocalApiServer server;
    late int port;
    const testApiKey = 'test-api-key-12345';
    const authHeaders = {'Authorization': 'Bearer $testApiKey'};

    Future<HttpClientResponse> get(String path) async {
      final client = HttpClient();
      final request = await client.get('localhost', port, path);
      authHeaders.forEach((k, v) => request.headers.add(k, v));
      return request.close();
    }

    Future<HttpClientResponse> post(String path, {required String body}) async {
      final client = HttpClient();
      final request = await client.post('localhost', port, path);
      request.headers.contentType = ContentType.json;
      final bytes = utf8.encode(body);
      request.contentLength = bytes.length;
      authHeaders.forEach((k, v) => request.headers.add(k, v));
      request.add(bytes);
      return request.close();
    }

    Future<Map<String, dynamic>> readJson(HttpClientResponse r) async {
      final text = await r.transform(utf8.decoder).join();
      return jsonDecode(text) as Map<String, dynamic>;
    }

    setUp(() async {
      alarmService = AlarmService();
      container = ProviderContainer(overrides: [
        alarmServiceProvider.overrideWith((ref) => alarmService),
      ]);
      displayService = DisplayModeService();
      configNotifier = _MemoryHubConfigNotifier();
      configNotifier.state = const HubConfig(apiKey: testApiKey);
      server = LocalApiServer(
        displayModeService: displayService,
        configNotifier: configNotifier,
        readProvider: container.read,
        plugins: [AlarmClockPlugin()],
      );
      port = await server.start(port: 0);
    });

    tearDown(() async {
      await server.stop();
      displayService.dispose();
      container.dispose();
    });

    test('GET returns the live alarm list plus builtin tones', () async {
      alarmService.addAlarm(const Alarm(
        id: 'a1',
        time: '07:30',
        label: 'Wake',
        days: [1, 2, 3, 4, 5],
      ));

      final r = await get('/api/plugin/hearth.alarm_clock/alarms');
      expect(r.statusCode, 200);
      final json = await readJson(r);

      final alarms = json['alarms'] as List;
      expect(alarms.single['id'], 'a1');
      expect(alarms.single['time'], '07:30');
      expect(alarms.single['label'], 'Wake');
      // The server attaches a human day summary for the list row.
      expect(alarms.single['daySummary'], 'Weekdays');

      final tones = json['tones'] as List;
      expect(tones, isNotEmpty);
      expect(tones.first, containsPair('id', isA<String>()));
      expect(tones.first, containsPair('name', isA<String>()));
    });

    test('GET offers dimmable lights, by name, for the sunrise', () async {
      HaEntity light(String id, String name, List<String> modes) => HaEntity(
            entityId: id,
            state: 'off',
            attributes: {'friendly_name': name, 'supported_color_modes': modes},
            lastChanged: DateTime(2026),
          );
      await server.stop();
      container.dispose();
      container = ProviderContainer(overrides: [
        alarmServiceProvider.overrideWith((ref) => alarmService),
        homeAssistantServiceProvider.overrideWith((ref) => FakeHomeAssistant([
              light('light.zed', 'Zed Lamp', ['brightness']),
              light('light.bed', 'Bedside', ['color_temp', 'rgb']),
              light('light.switch', 'Lamp Switch', ['onoff']),
            ])),
      ]);
      server = LocalApiServer(
        displayModeService: displayService,
        configNotifier: configNotifier,
        readProvider: container.read,
        plugins: [AlarmClockPlugin()],
      );
      port = await server.start(port: 0);

      final r = await get('/api/plugin/hearth.alarm_clock/alarms');
      final json = await readJson(r);

      expect(json['lights'], [
        {'id': 'light.bed', 'name': 'Bedside'},
        {'id': 'light.zed', 'name': 'Zed Lamp'},
      ]);
    });

    test('POST alarms/save keeps the picked sunrise lights', () async {
      await post('/api/plugin/hearth.alarm_clock/alarms/save',
          body: jsonEncode({
            'time': '06:15',
            'sunriseDuration': 10,
            'sunriseLights': ['light.bed'],
          }));
      expect(alarmService.alarms.single.sunriseLights, ['light.bed']);
    });

    test('POST alarms/save with no id adds a new alarm', () async {
      expect(alarmService.alarms, isEmpty);

      final r = await post('/api/plugin/hearth.alarm_clock/alarms/save',
          body: jsonEncode({
            'time': '06:15',
            'label': 'Run',
            'enabled': true,
            'days': [6, 7],
            'oneTime': false,
            'soundId': 'birds',
            'sunriseDuration': 10,
            'snoozeDuration': 5,
            'volume': 0.5,
          }));
      expect(r.statusCode, 200);
      final json = await readJson(r);
      expect(json['status'], 'saved');
      final newId = json['id'] as String;
      expect(newId, isNotEmpty);

      expect(alarmService.alarms, hasLength(1));
      final saved = alarmService.alarms.single;
      expect(saved.id, newId);
      expect(saved.time, '06:15');
      expect(saved.label, 'Run');
      expect(saved.days, [6, 7]);
      expect(saved.soundId, 'birds');
      expect(saved.sunriseDuration, 10);
      expect(saved.snoozeDuration, 5);
      expect(saved.volume, 0.5);
    });

    test('POST alarms/save with a known id updates in place', () async {
      alarmService.addAlarm(const Alarm(id: 'a1', time: '07:00', label: 'Old'));

      final r = await post('/api/plugin/hearth.alarm_clock/alarms/save',
          body: jsonEncode({
            'id': 'a1',
            'time': '08:45',
            'label': 'New',
            'enabled': false,
            'days': <int>[],
            'oneTime': true,
          }));
      expect(r.statusCode, 200);
      expect((await readJson(r))['id'], 'a1');

      // No new alarm — updated in place.
      expect(alarmService.alarms, hasLength(1));
      final updated = alarmService.alarms.single;
      expect(updated.id, 'a1');
      expect(updated.time, '08:45');
      expect(updated.label, 'New');
      expect(updated.enabled, false);
    });

    test('POST alarms/delete removes the alarm by id', () async {
      alarmService.addAlarm(const Alarm(id: 'a1', time: '07:00'));
      alarmService.addAlarm(const Alarm(id: 'a2', time: '09:00'));

      final r = await post('/api/plugin/hearth.alarm_clock/alarms/delete',
          body: jsonEncode({'id': 'a1'}));
      expect(r.statusCode, 200);
      final json = await readJson(r);
      expect(json['status'], 'deleted');
      expect(json['id'], 'a1');

      expect(alarmService.alarms.map((a) => a.id), ['a2']);
    });

    test('POST alarms/delete without an id is a 400', () async {
      alarmService.addAlarm(const Alarm(id: 'a1', time: '07:00'));

      final r = await post('/api/plugin/hearth.alarm_clock/alarms/delete',
          body: jsonEncode({}));
      expect(r.statusCode, 400);
      // The alarm is untouched.
      expect(alarmService.alarms.map((a) => a.id), ['a1']);
    });
  });
}

/// [HubConfigNotifier] that skips disk persistence so tests can call [update]
/// without the Flutter binding or path_provider.
class _MemoryHubConfigNotifier extends HubConfigNotifier {
  @override
  Future<void> update(HubConfig Function(HubConfig) updater) async {
    state = updater(state);
  }
}
