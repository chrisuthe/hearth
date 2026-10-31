import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/app/screen_navigator.dart';
import 'package:hearth/config/hub_config.dart';
import 'package:hearth/models/hearth_notification.dart';
import 'package:hearth/modules/alarm_clock/alarm_models.dart';
import 'package:hearth/modules/alarm_clock/alarm_service.dart';
import 'package:hearth/modules/alarm_clock/sunrise_controller.dart';
import 'package:hearth/services/mqtt_service.dart';
import 'package:hearth/services/notification_service.dart';
import 'package:hearth/services/timer_service.dart';

/// Keeps config in memory: the real notifier writes to the app-support dir.
class _MemoryConfigNotifier extends HubConfigNotifier {
  _MemoryConfigNotifier(HubConfig c) {
    state = c;
  }

  int writes = 0;

  @override
  Future<void> update(HubConfig Function(HubConfig) updater) async {
    writes++;
    state = updater(state);
  }
}

/// Counts connection attempts instead of dialing a broker.
class _CountingMqttService extends MqttService {
  _CountingMqttService(super.ref, {super.hostname, super.random});

  int connects = 0;

  @override
  Future<void> connect() async => connects++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MqttService.parseBroker', () {
    test('bare host defaults to port 1883, not secure', () {
      final r = MqttService.parseBroker('192.168.1.10');
      expect(r.host, '192.168.1.10');
      expect(r.port, 1883);
      expect(r.secure, false);
    });

    test('host:port parses both', () {
      final r = MqttService.parseBroker('broker.local:1884');
      expect(r.host, 'broker.local');
      expect(r.port, 1884);
      expect(r.secure, false);
    });

    test('mqtt:// scheme is stripped', () {
      final r = MqttService.parseBroker('mqtt://10.0.0.5:1883');
      expect(r.host, '10.0.0.5');
      expect(r.port, 1883);
      expect(r.secure, false);
    });

    test('mqtts:// implies secure and default port 8883', () {
      final r = MqttService.parseBroker('mqtts://broker.local');
      expect(r.host, 'broker.local');
      expect(r.port, 8883);
      expect(r.secure, true);
    });

    test('trailing path is stripped', () {
      final r = MqttService.parseBroker('mqtt://broker.local:1883/ignored');
      expect(r.host, 'broker.local');
      expect(r.port, 1883);
    });
  });

  group('MqttService.resolveDeviceId', () {
    final generated = RegExp(r'^hearth_[0-9a-f]{8}$');
    ({String id, String? legacyId}) resolve(String Function() host) =>
        MqttService.resolveDeviceId(hostname: host, random: Random(1));

    test('a Pi hostname keeps its sanitized id', () {
      expect(resolve(() => 'hearth').id, 'hearth');
      expect(resolve(() => 'hearthDev').id, 'hearthdev');
      expect(resolve(() => 'kitchen-pi').id, 'kitchen_pi');
      expect(resolve(() => 'hearth').legacyId, isNull);
    });

    test('localhost gets a generated id and clears the old one', () {
      final r = resolve(() => 'localhost');
      expect(r.id, matches(generated));
      expect(r.legacyId, 'localhost');
    });

    test('an empty hostname gets a generated id, never bare hearth', () {
      expect(resolve(() => '').id, matches(generated));
      expect(resolve(() => '-').id, matches(generated));
      expect(resolve(() => '').legacyId, isNull);
    });

    test('a failed lookup gets a generated id and clears nothing', () {
      final r = resolve(() => throw const SocketException('no hostname'));
      expect(r.id, matches(generated));
      // The fallback used to be `hearth`, which a Pi may still own.
      expect(r.legacyId, isNull);
    });
  });

  group('MqttService.defaultDeviceName', () {
    test('a Pi named hearth stays Hearth', () {
      expect(MqttService.defaultDeviceName(hostname: 'hearth'), 'Hearth');
    });

    test('another hostname is shown', () {
      expect(MqttService.defaultDeviceName(hostname: 'hearthDev'),
          'Hearth (hearthDev)');
    });

    test('without a hostname the model is shown', () {
      expect(MqttService.defaultDeviceName(model: 'Apolosign Calendar'),
          'Hearth (Apolosign Calendar)');
      expect(MqttService.defaultDeviceName(), 'Hearth');
    });
  });

  group('MqttService device id lifecycle', () {
    const broker = HubConfig(mqttBrokerUrl: 'mqtt://10.0.0.5:1883');

    ({ProviderContainer container, _MemoryConfigNotifier config,
        _CountingMqttService service}) start(
      HubConfig initial,
      String Function() hostname,
    ) {
      final notifier = _MemoryConfigNotifier(initial);
      final serviceProvider = ChangeNotifierProvider((ref) {
        final s =
            _CountingMqttService(ref, hostname: hostname, random: Random(7));
        ref.listen<HubConfig>(hubConfigProvider, (_, n) => s.updateConfig(n),
            fireImmediately: true);
        return s;
      });
      final container = ProviderContainer(
          overrides: [hubConfigProvider.overrideWith((ref) => notifier)]);
      addTearDown(container.dispose);
      return (
        container: container,
        config: notifier,
        service: container.read(serviceProvider),
      );
    }

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test('a generated id is persisted once and reused after a restart',
        () async {
      final first = start(broker, () => 'localhost');
      await settle();
      final id = first.config.state.mqttDeviceId;
      expect(id, matches(RegExp(r'^hearth_[0-9a-f]{8}$')));
      expect(first.service.deviceId, id);
      expect(first.config.writes, 1);

      final second = start(first.config.state, () => 'localhost');
      await settle();
      expect(second.service.deviceId, id);
      expect(second.config.writes, 0);
    });

    test('a stored id wins over the hostname', () async {
      final r = start(
          broker.copyWith(mqttDeviceId: 'hearth_0a1b2c3d'), () => 'hearthDev');
      await settle();
      expect(r.service.deviceId, 'hearth_0a1b2c3d');
      expect(r.config.writes, 0);
    });

    test('a Pi persists its hostname id', () async {
      final r = start(broker, () => 'hearth');
      await settle();
      expect(r.config.state.mqttDeviceId, 'hearth');
    });

    test('persisting the id does not reconnect', () async {
      final r = start(broker, () => 'localhost');
      await settle();
      expect(r.config.writes, 1);
      expect(r.service.connects, 1);
    });

    test('renaming the device does not reconnect', () async {
      final r = start(broker, () => 'hearth');
      await settle();
      await r.config.update((c) => c.copyWith(mqttDeviceName: 'Kitchen'));
      expect(r.service.connects, 1);
    });

    test('no id is assigned until a broker is configured', () async {
      final r = start(const HubConfig(), () => 'localhost');
      await settle();
      expect(r.config.state.mqttDeviceId, isEmpty);
      expect(r.service.connects, 0);
    });
  });

  group('MqttService.buildDiscoveryEntries', () {
    final entries = MqttService.buildDiscoveryEntries(
      clientId: 'kitchen',
      discoveryPrefix: 'homeassistant',
      swVersion: '1.2.3',
      configurationUrl: 'http://kitchen:8090',
    );

    test('covers every exposed entity', () {
      expect(entries.length, 6);
      final uids = entries.map((e) => e.config['unique_id']).toSet();
      expect(uids, {
        'hearth_kitchen_current_screen',
        'hearth_kitchen_now_playing',
        'hearth_kitchen_timer',
        'hearth_kitchen_next_alarm',
        'hearth_kitchen_screen',
        'hearth_kitchen_volume',
      });
    });

    test('screen select carries its options and command topic', () {
      final e = MqttService.buildDiscoveryEntries(
        clientId: 'kitchen',
        discoveryPrefix: 'homeassistant',
        swVersion: '1.2.3',
        configurationUrl: null,
        screenOptions: const ['Music', 'Home', 'Settings'],
      ).firstWhere((e) => e.config['unique_id'] == 'hearth_kitchen_screen');
      expect(e.topic, 'homeassistant/select/hearth_kitchen/screen/config');
      expect(e.config['options'], ['Music', 'Home', 'Settings']);
      expect(e.config['command_topic'], 'hearth/kitchen/screen/set');
      expect(e.config['state_topic'], 'hearth/kitchen/screen/state');
    });

    test('screen options name each screen once', () {
      expect(
        MqttService.screenOptions(const [
          ShellScreen(id: 'home', name: 'Home'),
          ShellScreen(id: 'webview:a', name: 'Dashboard'),
          ShellScreen(id: 'webview:b', name: 'Dashboard'),
          ShellScreen(id: 'settings', name: 'Settings'),
        ]),
        ['Home', 'Dashboard', 'Settings'],
      );
    });

    test('every entry shares one identical device-identity block', () {
      final devices = entries.map((e) => e.config['device']).toList();
      for (final d in devices) {
        expect(d, devices.first);
      }
      final device = devices.first as Map<String, dynamic>;
      expect(device['identifiers'], ['hearth_kitchen']);
      expect(device['name'], 'Hearth');
      expect(device['sw_version'], '1.2.3');
      expect(device['configuration_url'], 'http://kitchen:8090');
    });

    test('discovery topics follow the HA <prefix>/<component>/.../config shape', () {
      final byUid = {
        for (final e in entries) e.config['unique_id'] as String: e.topic,
      };
      expect(byUid['hearth_kitchen_current_screen'],
          'homeassistant/sensor/hearth_kitchen/current_screen/config');
      expect(byUid['hearth_kitchen_volume'],
          'homeassistant/number/hearth_kitchen/volume/config');
    });

    test('volume number carries a command topic and 0-100 range', () {
      final volume = entries
          .firstWhere((e) => e.config['unique_id'] == 'hearth_kitchen_volume')
          .config;
      expect(volume['command_topic'], 'hearth/kitchen/volume/set');
      expect(volume['min'], 0);
      expect(volume['max'], 100);
    });

    test('the device name is sent in the device block', () {
      final e = MqttService.buildDiscoveryEntries(
        clientId: 'k',
        discoveryPrefix: 'homeassistant',
        swVersion: '1.2.3',
        configurationUrl: 'http://10.0.1.80:8090',
        deviceName: 'Hearth (Apolosign Calendar)',
      );
      expect((e.first.config['device'] as Map)['name'],
          'Hearth (Apolosign Calendar)');
    });

    test('no configuration_url is sent when none is known', () {
      final e = MqttService.buildDiscoveryEntries(
        clientId: 'k',
        discoveryPrefix: 'homeassistant',
        swVersion: '1.2.3',
        configurationUrl: null,
      );
      expect(e.first.config['device'] as Map,
          isNot(contains('configuration_url')));
    });

    test('volume is left out where it cannot be read', () {
      final e = MqttService.buildDiscoveryEntries(
        clientId: 'k',
        discoveryPrefix: 'homeassistant',
        swVersion: '1.2.3',
        configurationUrl: null,
        includeVolume: false,
      );
      expect(e.length, 5);
      expect(e.map((x) => x.topic),
          isNot(contains(MqttService.volumeDiscoveryTopic('homeassistant', 'k'))));
    });

    test('empty version falls back to "unknown"', () {
      final e = MqttService.buildDiscoveryEntries(
        clientId: 'k',
        discoveryPrefix: 'homeassistant',
        swVersion: '',
        configurationUrl: 'http://k:8090',
      );
      expect((e.first.config['device'] as Map)['sw_version'], 'unknown');
    });
  });

  group('MqttService.handleCommand (inbound)', () {
    late ProviderContainer container;
    late MqttService service;
    late TimerService timers;
    late AlarmService alarms;
    late NotificationService notifications;
    String topic(String suffix) => 'hearth/kitchen/$suffix';

    setUp(() {
      container = ProviderContainer(overrides: [
        hubConfigProvider.overrideWith((ref) =>
            _MemoryConfigNotifier(const HubConfig(mqttDeviceId: 'kitchen'))),
        // Use a silent chime so no audio subprocess is spawned in tests.
        notificationServiceProvider.overrideWith(
          (ref) => NotificationService(playChime: (_) async {}),
        ),
      ]);
      service = container.read(mqttServiceProvider);
      timers = container.read(timerServiceProvider);
      alarms = container.read(alarmServiceProvider);
      notifications = container.read(notificationServiceProvider);
    });

    tearDown(() => container.dispose());

    test('screen/set asks HubShell for the named screen', () async {
      final seen = <String>[];
      final sub =
          container.read(screenNavigatorProvider).requests.listen(seen.add);
      await service.handleCommand(topic('screen/set'), 'Cameras');
      await service.handleCommand(topic('screen/set'), 'media');
      await service.handleCommand(topic('screen/set'), 'Nowhere');
      await Future<void>.delayed(Duration.zero);
      expect(seen, ['cameras', 'media']);
      await sub.cancel();
    });

    test('timer/start starts a timer of the given duration', () {
      service.handleCommand(topic('timer/start'), '{"duration": 300}');
      expect(timers.timers.length, 1);
      expect(timers.timers.first.totalDuration.inSeconds, 300);
    });

    test('timer/start ignores a malformed payload', () {
      service.handleCommand(topic('timer/start'), 'not json');
      service.handleCommand(topic('timer/start'), '{"duration": 0}');
      expect(timers.timers, isEmpty);
    });

    test('timer/cancel with no id dismisses the newest timer', () {
      service.handleCommand(topic('timer/start'), '{"duration": 60}');
      service.handleCommand(topic('timer/start'), '{"duration": 600}');
      expect(timers.timers.length, 2);
      service.handleCommand(topic('timer/cancel'), '{}');
      expect(timers.timers.length, 1);
    });

    test('timer/cancel with an id dismisses that timer', () {
      service.handleCommand(topic('timer/start'), '{"duration": 60}');
      final id = timers.timers.first.id;
      service.handleCommand(topic('timer/cancel'), '{"timer_id": $id}');
      expect(timers.timers, isEmpty);
    });

    test('alarm/create adds an alarm with the given fields', () {
      service.handleCommand(
        topic('alarm/create'),
        '{"time": "07:30", "label": "Wake", "days": [1, 2, 3, 4, 5]}',
      );
      expect(alarms.alarms.length, 1);
      final a = alarms.alarms.first;
      expect(a.time, '07:30');
      expect(a.label, 'Wake');
      expect(a.days, [1, 2, 3, 4, 5]);
    });

    test('alarm/create ignores a payload with no time', () {
      service.handleCommand(topic('alarm/create'), '{"label": "x"}');
      expect(alarms.alarms, isEmpty);
    });

    test('alarm/delete removes the named alarm', () {
      alarms.addAlarm(const Alarm(id: 'abc123', time: '06:00'));
      expect(alarms.alarms.length, 1);
      service.handleCommand(topic('alarm/delete'), '{"alarm_id": "abc123"}');
      expect(alarms.alarms, isEmpty);
    });

    test('alarm/snooze snoozes the firing alarm', () {
      const alarm = Alarm(id: 'a1', time: '06:00', snoozeDuration: 9);
      alarms.addAlarm(alarm);
      alarms.fireAlarmForTest(alarm);
      expect(alarms.firedAlarm, isNotNull);
      service.handleCommand(topic('alarm/snooze'), '');
      expect(alarms.firedAlarm, isNull);
      expect(alarms.snoozedUntil, isNotNull);
    });

    test('alarm/dismiss clears the firing alarm', () {
      const alarm = Alarm(id: 'a2', time: '06:00');
      alarms.addAlarm(alarm);
      alarms.fireAlarmForTest(alarm);
      expect(alarms.firedAlarm, isNotNull);
      service.handleCommand(topic('alarm/dismiss'), '');
      expect(alarms.firedAlarm, isNull);
    });

    test('alarm/snooze sends the sunrise back to climb again', () {
      const alarm = Alarm(id: 'a3', time: '06:00', sunriseDuration: 15);
      alarms.addAlarm(alarm);
      alarms.fireAlarmForTest(alarm);
      final sunrise = container.read(sunriseControllerProvider);
      expect(sunrise.progress, 1);

      service.handleCommand(topic('alarm/snooze'), '');

      expect(sunrise.active, isTrue);
      expect(sunrise.progress, closeTo(kSunriseSnoozeLevel, 0.01));
    });

    test('alarm/dismiss ends the sunrise', () {
      const alarm = Alarm(id: 'a4', time: '06:00', sunriseDuration: 15);
      alarms.addAlarm(alarm);
      alarms.fireAlarmForTest(alarm);
      final sunrise = container.read(sunriseControllerProvider);
      expect(sunrise.active, isTrue);

      service.handleCommand(topic('alarm/dismiss'), '');

      expect(sunrise.active, isFalse);
    });

    test('alarm/delete ends a sunrise in progress', () {
      const alarm = Alarm(id: 'a5', time: '06:00', sunriseDuration: 15);
      alarms.addAlarm(alarm);
      alarms.fireAlarmForTest(alarm);
      final sunrise = container.read(sunriseControllerProvider);
      expect(sunrise.active, isTrue);

      service.handleCommand(topic('alarm/delete'), '{"alarm_id": "a5"}');

      expect(sunrise.active, isFalse);
    });

    test('alarm/create leaves the sunrise off unless asked', () {
      service.handleCommand(topic('alarm/create'), '{"time": "07:30"}');
      service.handleCommand(
          topic('alarm/create'), '{"time": "08:30", "sunrise_duration": 20}');
      expect(alarms.alarms.first.sunriseDuration, 0);
      expect(alarms.alarms.last.sunriseDuration, 20);
    });

    test('an unknown command topic is a no-op', () {
      service.handleCommand(topic('bogus/thing'), 'payload');
      expect(timers.timers, isEmpty);
      expect(alarms.alarms, isEmpty);
    });

    test('notify ingests a normalized card', () async {
      await service.handleCommand(
        topic('notify'),
        '{"title": "Doorbell", "message": "Someone is at the door", '
            '"priority": "alert", "sticky": true}',
      );
      expect(notifications.notifications, hasLength(1));
      final n = notifications.notifications.first;
      expect(n.title, 'Doorbell');
      expect(n.body, 'Someone is at the door');
      expect(n.priority, NotificationPriority.alert);
      expect(n.sticky, true);
      // Defaults to the HA source when the payload doesn't specify one.
      expect(n.source, NotificationSource.ha);
      expect(n.sourceLabel, 'HOME ASST');
    });

    test('notify defaults priority to info and infers stickiness', () async {
      await service.handleCommand(
        topic('notify'),
        '{"message": "Package delivered"}',
      );
      final n = notifications.notifications.single;
      expect(n.priority, NotificationPriority.info);
      // Info without an explicit sticky flag is transient.
      expect(n.sticky, false);
      expect(n.title, 'Package delivered');
    });

    test('notify honours an explicit source and label', () async {
      await service.handleCommand(
        topic('notify'),
        '{"title": "Motion", "source": "frigate"}',
      );
      final n = notifications.notifications.single;
      expect(n.source, NotificationSource.frigate);
      expect(n.sourceLabel, 'FRIGATE');
    });

    test('notify ignores a payload with no title or message', () async {
      await service.handleCommand(topic('notify'), '{"priority": "alert"}');
      await service.handleCommand(topic('notify'), 'not json');
      expect(notifications.notifications, isEmpty);
    });

    test('notify with clear closes the tagged card', () async {
      await service.handleCommand(
          topic('notify'), '{"title": "Person", "tag": "door"}');
      expect(notifications.notifications, hasLength(1));
      await service.handleCommand(
          topic('notify'), '{"tag": "door", "clear": true}');
      expect(notifications.notifications, isEmpty);
    });
  });
}
