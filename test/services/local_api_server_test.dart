import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hearth/app/current_screen_provider.dart';
import 'package:hearth/app/screen_navigator.dart';
import 'package:hearth/config/hub_config.dart';
import 'package:hearth/modules/calendar/models.dart';
import 'package:hearth/plugins/capture/capture_plugin.dart';
import 'package:hearth/plugins/plugin_registry.dart';
import 'package:hearth/services/local_api_server.dart';
import 'package:hearth/services/display_mode_service.dart';
import 'package:hearth/services/capture_service.dart';
import 'package:hearth/services/notification_service.dart';
import 'package:hearth/services/app_updater.dart';
import 'package:hearth/services/update_service.dart';
import 'package:hearth/models/hearth_notification.dart';

void main() {
  group('LocalApiServer', () {
    late DisplayModeService displayService;
    late HubConfigNotifier configNotifier;
    late LocalApiServer server;
    late int port;
    const testApiKey = 'test-api-key-12345';

    Future<HttpClientResponse> get(String path,
        {Map<String, String>? headers}) async {
      final client = HttpClient();
      final request = await client.get('localhost', port, path);
      headers?.forEach((k, v) => request.headers.add(k, v));
      return request.close();
    }

    Future<HttpClientResponse> post(String path,
        {required String body, Map<String, String>? headers}) async {
      final client = HttpClient();
      final request = await client.post('localhost', port, path);
      request.headers.contentType = ContentType.json;
      headers?.forEach((k, v) => request.headers.add(k, v));
      // Set an explicit Content-Length (real browser fetch always does). The
      // plugin route dispatch only decodes a POST body when contentLength > 0,
      // so a chunked request (length -1) would arrive with an empty body.
      final bytes = utf8.encode(body);
      request.contentLength = bytes.length;
      request.add(bytes);
      return request.close();
    }

    Future<HttpClientResponse> delete(String path,
        {Map<String, String>? headers}) async {
      final client = HttpClient();
      final request = await client.delete('localhost', port, path);
      headers?.forEach((k, v) => request.headers.add(k, v));
      return request.close();
    }

    const authHeaders = {'Authorization': 'Bearer $testApiKey'};

    setUp(() async {
      displayService = DisplayModeService();
      configNotifier = _MemoryHubConfigNotifier();
      configNotifier.state = const HubConfig(apiKey: testApiKey);
      server = LocalApiServer(
        displayModeService: displayService,
        configNotifier: configNotifier,
      );
      port = await server.start(port: 0);
    });

    tearDown(() async {
      await server.stop();
      displayService.dispose();
    });

    Future<String> readBody(HttpClientResponse response) =>
        response.transform(utf8.decoder).join();

    // --- Auth tests ---

    test('rejects /api/* requests without auth', () async {
      final response = await get('/api/config');
      expect(response.statusCode, 401);
    });

    test('rejects /api/* requests with wrong token', () async {
      final response =
          await get('/api/config', headers: {'Authorization': 'Bearer wrong'});
      expect(response.statusCode, 401);
    });

    test('allows /api/* requests with correct Bearer token', () async {
      final response = await get('/api/config', headers: authHeaders);
      expect(response.statusCode, 200);
    });

    test('config page at / shows PIN page without session', () async {
      final response = await get('/');
      expect(response.statusCode, 200);
      final body = await readBody(response);
      expect(body, contains('Enter the PIN'));
    });

    // --- PIN auth tests ---

    test('POST /auth/pin with correct PIN returns session cookie', () async {
      final pin = server.webPin;
      final response = await post('/auth/pin',
          body: jsonEncode({'pin': pin}));
      expect(response.statusCode, 200);
      final setCookie = response.headers['set-cookie'];
      expect(setCookie, isNotNull);
      final cookieStr = setCookie!.first;
      expect(cookieStr, contains('hearth_session='));
      expect(cookieStr, contains('HttpOnly'));
    });

    test('POST /auth/pin with wrong PIN returns 401', () async {
      final response = await post('/auth/pin',
          body: jsonEncode({'pin': '0000'}));
      expect(response.statusCode, 401);
    });

    test('config page at / is accessible with valid session', () async {
      // First, authenticate
      final pin = server.webPin;
      final authResponse = await post('/auth/pin',
          body: jsonEncode({'pin': pin}));
      final setCookie = authResponse.headers['set-cookie']!.first;
      final cookieMatch = RegExp(r'hearth_session=(\w+)').firstMatch(setCookie);
      final sessionCookie = 'hearth_session=${cookieMatch!.group(1)}';

      // Now access the config page with the session cookie
      final response = await get('/',
          headers: {'Cookie': sessionCookie});
      expect(response.statusCode, 200);
      final body = await readBody(response);
      // WebRenderer-rendered settings shell: title + sidebar with a
      // plugin category header.
      expect(body, contains('Hearth Settings'));
      expect(body, contains('FEATURES'));
    });

    test('GET /api/session/key returns API key with valid session', () async {
      final pin = server.webPin;
      final authResponse = await post('/auth/pin',
          body: jsonEncode({'pin': pin}));
      final setCookie = authResponse.headers['set-cookie']!.first;
      final cookieMatch = RegExp(r'hearth_session=(\w+)').firstMatch(setCookie);
      final sessionCookie = 'hearth_session=${cookieMatch!.group(1)}';

      final response = await get('/api/session/key',
          headers: {'Cookie': sessionCookie});
      expect(response.statusCode, 200);
      final json = jsonDecode(await readBody(response)) as Map<String, dynamic>;
      expect(json['apiKey'], testApiKey);
    });

    test('GET /api/session/key returns 401 without session', () async {
      final response = await get('/api/session/key');
      expect(response.statusCode, 401);
    });

    // --- Plugin icons (web sidebar + panel header) ---

    Future<String> unlockSession() async {
      final pin = server.webPin;
      final authResp =
          await post('/auth/pin', body: jsonEncode({'pin': pin}));
      final setCookie = authResp.headers['set-cookie']!.first;
      final match = RegExp(r'hearth_session=(\w+)').firstMatch(setCookie);
      return 'hearth_session=${match!.group(1)}';
    }

    test('web settings HTML emits plugin icon codepoints for sidebar + header',
        () async {
      final cookie = await unlockSession();
      final response = await get('/', headers: {'Cookie': cookie});
      expect(response.statusCode, 200);
      final body = await readBody(response);

      // Every plugin row carries an icon span, and the panel header too.
      expect(body, contains('class="row-icon"'));
      expect(body, contains('class="panel-icon"'));

      // The selected (first visible) plugin's icon codepoint is emitted as an
      // HTML entity, before its name. Compute the expected codepoint from the
      // real registry rather than hardcoding a glyph.
      final visible = firstPartyPlugins
          .where((p) => p.isVisible(const HubConfig(apiKey: testApiKey)))
          .toList();
      expect(visible, isNotEmpty);
      final first = visible.first;
      final entity = '&#x${first.icon.codePoint.toRadixString(16)};';
      // The icon span (glyph entity) precedes the plugin name in the row.
      expect(body, contains('<span class="row-icon">$entity</span>'));
      expect(body, contains('</span>${first.name}'));
    });

    test('GET /assets/material-icons.otf returns font bytes with font type',
        () async {
      await server.stop();
      final fontServer = LocalApiServer(
        displayModeService: displayService,
        configNotifier: configNotifier,
        loadIconFont: () async => <int>[0x4F, 0x54, 0x54, 0x4F, 0x00, 0x01],
      );
      final fontPort = await fontServer.start(port: 0);
      try {
        final client = HttpClient();
        final request =
            await client.get('localhost', fontPort, '/assets/material-icons.otf');
        final response = await request.close();
        expect(response.statusCode, 200);
        expect(response.headers.contentType?.primaryType, 'font');
        final bytes =
            await response.fold<List<int>>([], (acc, c) => acc..addAll(c));
        expect(bytes, isNotEmpty);
      } finally {
        await fontServer.stop();
      }
    });

    // --- Secret redaction ---

    test('GET /api/config redacts secret fields', () async {
      configNotifier.state = const HubConfig(
        apiKey: testApiKey,
        haToken: 'super-secret-token',
        immichApiKey: 'immich-key-123',
        musicAssistantToken: 'ma-token-456',
        haUrl: 'http://ha.local:8123',
      );

      final response = await get('/api/config', headers: authHeaders);
      final json = jsonDecode(await readBody(response)) as Map<String, dynamic>;

      expect(json['haToken'], '••••••••');
      expect(json['immichApiKey'], '••••••••');
      expect(json['musicAssistantToken'], '••••••••');
      expect(json['apiKey'], '••••••••');
      expect(json['haUrl'], 'http://ha.local:8123');
    });

    test('GET /api/config shows empty string for unset secrets', () async {
      final response = await get('/api/config', headers: authHeaders);
      final json = jsonDecode(await readBody(response)) as Map<String, dynamic>;
      expect(json['haToken'], '');
      expect(json['immichApiKey'], '');
    });

    // ICS URLs can carry a secret (Google's private iCal address).
    const icsUrl = 'https://calendar.example.com/private-abc123/basic.ics';
    const school = CalendarSource(
      id: 'ics:0011223344556677',
      kind: CalendarSourceKind.ics,
      url: icsUrl,
      name: 'School',
    );
    const family = CalendarSource(
      id: 'ha:calendar.family',
      kind: CalendarSourceKind.ha,
      entityId: 'calendar.family',
      name: 'Family',
    );

    test('GET /api/config redacts ICS source URLs', () async {
      configNotifier.state = const HubConfig(
          apiKey: testApiKey, calendarSources: [family, school]);
      final response = await get('/api/config', headers: authHeaders);
      final text = await readBody(response);
      expect(text, isNot(contains('private-abc123')));
      final sources = (jsonDecode(text) as Map)['calendarSources'] as List;
      expect(sources.last['url'], '••••••••');
      expect(sources.last['name'], 'School');
      expect(sources.first['url'], '');
      expect(sources.first['entityId'], 'calendar.family');
    });

    test('POST /api/config keeps a stored ICS URL echoed as the marker',
        () async {
      configNotifier.state = const HubConfig(
          apiKey: testApiKey, calendarSources: [family, school]);
      final get1 = await get('/api/config', headers: authHeaders);
      final sources = ((jsonDecode(await readBody(get1)) as Map)
          ['calendarSources'] as List);
      sources.last['name'] = 'Kids';

      final r = await post('/api/config',
          body: jsonEncode({'calendarSources': sources}),
          headers: authHeaders);
      expect(r.statusCode, 200);
      final saved = configNotifier.state.calendarSources;
      expect(saved.map((s) => s.id), [family.id, school.id]);
      expect(saved.last.url, icsUrl);
      expect(saved.last.name, 'Kids');
      expect(saved.first, family);
    });

    test('POST /api/config takes a new ICS URL and drops a marker with no '
        'stored source', () async {
      configNotifier.state =
          const HubConfig(apiKey: testApiKey, calendarSources: [school]);
      final r = await post('/api/config',
          body: jsonEncode({
            'calendarSources': [
              {...school.toJson(), 'url': 'https://example.com/new.ics'},
              {
                ...school.toJson(),
                'id': 'ics:ffffffffffffffff',
                'url': '••••••••',
              },
            ],
          }),
          headers: authHeaders);
      expect(r.statusCode, 200);
      final saved = configNotifier.state.calendarSources;
      expect(saved, hasLength(1));
      expect(saved.single.url, 'https://example.com/new.ics');
    });

    // --- Typed config writes (Enabler A) ---
    //
    // The web auto-save helper posts range/select/text values as strings.
    // POST /api/config must coerce each to its declared HubConfig type.

    test('POST /api/config coerces a string into a double field', () async {
      final r = await post('/api/config',
          body: jsonEncode({'uiScale': '1.25'}), headers: authHeaders);
      expect(r.statusCode, 200);
      expect(configNotifier.state.uiScale, 1.25);
    });

    test('POST /api/config coerces a string into an int field', () async {
      final r = await post('/api/config',
          body: jsonEncode({'sendspinBufferSeconds': '10'}),
          headers: authHeaders);
      expect(r.statusCode, 200);
      expect(configNotifier.state.sendspinBufferSeconds, 10);
    });

    test('POST /api/config saves idleTimeoutSeconds posted as a string',
        () async {
      // Regression: the old handler only accepted `is num`, so the range
      // slider's string value was silently dropped.
      final r = await post('/api/config',
          body: jsonEncode({'idleTimeoutSeconds': '300'}),
          headers: authHeaders);
      expect(r.statusCode, 200);
      expect(configNotifier.state.idleTimeoutSeconds, 300);
    });

    test('POST /api/config saves a bool field absent from the legacy handler',
        () async {
      // Regression: micMuted / showVoiceFeedback were rendered on web but not
      // in the old copyWith allow-list, so toggling them did nothing.
      final r = await post('/api/config',
          body: jsonEncode({'micMuted': true, 'showVoiceFeedback': false}),
          headers: authHeaders);
      expect(r.statusCode, 200);
      expect(configNotifier.state.micMuted, true);
      expect(configNotifier.state.showVoiceFeedback, false);
    });

    test('POST /api/config still saves plain string fields', () async {
      final r = await post('/api/config',
          body: jsonEncode({'haUrl': 'http://ha.local:8123'}),
          headers: authHeaders);
      expect(r.statusCode, 200);
      expect(configNotifier.state.haUrl, 'http://ha.local:8123');
    });

    test('POST /api/config ignores read-only keys (apiKey)', () async {
      final r = await post('/api/config',
          body: jsonEncode({'apiKey': 'attacker-key', 'haUrl': 'http://x'}),
          headers: authHeaders);
      expect(r.statusCode, 200);
      expect(configNotifier.state.apiKey, testApiKey);
      expect(configNotifier.state.haUrl, 'http://x');
    });

    test('POST /api/config ignores read-only dlnaUuid', () async {
      configNotifier.state =
          const HubConfig(apiKey: testApiKey, dlnaUuid: 'seeded-uuid');
      final r = await post('/api/config',
          body: jsonEncode({'dlnaUuid': 'attacker-uuid', 'haUrl': 'http://z'}),
          headers: authHeaders);
      expect(r.statusCode, 200);
      expect(configNotifier.state.dlnaUuid, 'seeded-uuid');
      expect(configNotifier.state.haUrl, 'http://z');
    });

    test('POST /api/config ignores read-only mqttDeviceId', () async {
      configNotifier.state =
          const HubConfig(apiKey: testApiKey, mqttDeviceId: 'hearth_0a1b2c3d');
      final r = await post('/api/config',
          body: jsonEncode({'mqttDeviceId': 'other', 'haUrl': 'http://m'}),
          headers: authHeaders);
      expect(r.statusCode, 200);
      expect(configNotifier.state.mqttDeviceId, 'hearth_0a1b2c3d');
      expect(configNotifier.state.haUrl, 'http://m');
    });

    test('POST /api/config ignores read-only voiceSatelliteMac', () async {
      configNotifier.state = const HubConfig(
          apiKey: testApiKey, voiceSatelliteMac: '0a:1b:2c:3d:4e:5f');
      final r = await post('/api/config',
          body: jsonEncode({
            'voiceSatelliteMac': 'ff:ff:ff:ff:ff:ff',
            'voiceWakeWords': ['hey_jarvis', 'okay_nabu'],
          }),
          headers: authHeaders);
      expect(r.statusCode, 200);
      expect(configNotifier.state.voiceSatelliteMac, '0a:1b:2c:3d:4e:5f');
      expect(configNotifier.state.voiceWakeWords, ['hey_jarvis', 'okay_nabu']);
    });

    test('POST /api/config ignores unknown keys without error', () async {
      final r = await post('/api/config',
          body: jsonEncode({'notARealField': 'whatever', 'haUrl': 'http://y'}),
          headers: authHeaders);
      expect(r.statusCode, 200);
      expect(configNotifier.state.haUrl, 'http://y');
    });

    test('POST /api/config leaves a secret untouched when posted redacted',
        () async {
      configNotifier.state =
          const HubConfig(apiKey: testApiKey, haToken: 'real-token');
      final r = await post('/api/config',
          body: jsonEncode({'haToken': '••••••••'}), headers: authHeaders);
      expect(r.statusCode, 200);
      expect(configNotifier.state.haToken, 'real-token');
    });

    test('POST /api/config does not corrupt typed fields with garbage',
        () async {
      configNotifier.state =
          const HubConfig(apiKey: testApiKey, sendspinBufferSeconds: 7);
      final r = await post('/api/config',
          body: jsonEncode({'sendspinBufferSeconds': 'not-a-number'}),
          headers: authHeaders);
      expect(r.statusCode, 200);
      // Unparseable value falls back to the existing value, not 0/null.
      expect(configNotifier.state.sendspinBufferSeconds, 7);
    });

    // --- Display mode ---

    test('POST /api/display-mode sets night mode', () async {
      final response = await post('/api/display-mode',
          body: jsonEncode({'mode': 'night'}), headers: authHeaders);
      expect(response.statusCode, 200);
      final json = jsonDecode(await readBody(response)) as Map<String, dynamic>;
      expect(json['mode'], 'night');
    });

    test('POST /api/display-mode sets day mode', () async {
      final response = await post('/api/display-mode',
          body: jsonEncode({'mode': 'day'}), headers: authHeaders);
      expect(response.statusCode, 200);
      final json = jsonDecode(await readBody(response)) as Map<String, dynamic>;
      expect(json['mode'], 'day');
    });

    test('GET /api/display-mode returns resolved mode', () async {
      configNotifier.state = const HubConfig(
        apiKey: testApiKey,
        nightModeSource: 'api',
      );
      displayService.setModeFromApi(DisplayMode.night);

      final response = await get('/api/display-mode', headers: authHeaders);
      final json = jsonDecode(await readBody(response)) as Map<String, dynamic>;
      expect(json['mode'], 'night');
    });

    // --- Screen ---

    group('screen', () {
      late ProviderContainer container;
      late ScreenNavigator navigator;
      late List<String> requests;

      setUp(() async {
        // The default swipe row: media · home · controls · cameras · settings.
        container = ProviderContainer(overrides: [
          hubConfigProvider.overrideWith((ref) => _MemoryHubConfigNotifier()),
        ]);
        navigator = container.read(screenNavigatorProvider);
        requests = [];
        navigator.requests.listen(requests.add);
        await server.stop();
        server = LocalApiServer(
          displayModeService: displayService,
          configNotifier: configNotifier,
          screenNavigator: navigator,
        );
        port = await server.start(port: 0);
      });

      tearDown(() => container.dispose());

      test('GET /api/screen lists the screens and the current one', () async {
        container.read(currentScreenProvider.notifier).state =
            const CurrentScreen(id: 'controls', index: 2);
        final r = await get('/api/screen', headers: authHeaders);
        expect(r.statusCode, 200);
        final json = jsonDecode(await readBody(r)) as Map<String, dynamic>;
        expect(json['screen'], 'controls');
        expect(json['index'], 2);
        expect(json['screens'], [
          {'id': 'media', 'name': 'Music'},
          {'id': 'home', 'name': 'Home'},
          {'id': 'controls', 'name': 'Controls'},
          {'id': 'cameras', 'name': 'Cameras'},
          {'id': 'settings', 'name': 'Settings'},
        ]);
      });

      test('POST /api/screen requests the screen by id or name', () async {
        var r = await post('/api/screen',
            body: jsonEncode({'screen': 'cameras'}), headers: authHeaders);
        expect(r.statusCode, 200);
        expect(jsonDecode(await readBody(r)), {'screen': 'cameras'});
        r = await post('/api/screen',
            body: jsonEncode({'screen': 'Music'}), headers: authHeaders);
        expect(jsonDecode(await readBody(r)), {'screen': 'media'});
        expect(requests, ['cameras', 'media']);
      });

      test('POST /api/screen rejects an unknown or missing screen', () async {
        var r = await post('/api/screen',
            body: jsonEncode({'screen': 'calendar'}), headers: authHeaders);
        expect(r.statusCode, 404);
        final json = jsonDecode(await readBody(r)) as Map<String, dynamic>;
        expect(json['screens'], contains('home'));
        r = await post('/api/screen', body: '{}', headers: authHeaders);
        expect(r.statusCode, 400);
        await readBody(r);
        expect(requests, isEmpty);
      });

      test('/api/screen requires the API key', () async {
        final r = await post('/api/screen',
            body: jsonEncode({'screen': 'home'}));
        expect(r.statusCode, 401);
        await readBody(r);
        expect(requests, isEmpty);
      });
    });

    test('/api/screen is 503 without a navigator', () async {
      final r = await get('/api/screen', headers: authHeaders);
      expect(r.statusCode, 503);
    });

    // --- Error handling ---

    test('malformed JSON body returns 500 without crashing server', () async {
      final response = await post('/api/config',
          body: 'not valid json {{{', headers: authHeaders);
      expect(response.statusCode, 500);

      // Server is still alive — can handle another request
      final response2 = await get('/api/config', headers: authHeaders);
      expect(response2.statusCode, 200);
    });

    test('unknown route returns 404', () async {
      final response = await get('/api/unknown', headers: authHeaders);
      expect(response.statusCode, 404);
    });

    // --- WiFi endpoints ---

    test('GET /api/wifi/scan returns JSON with networks array', () async {
      final response = await get('/api/wifi/scan',
          headers: authHeaders);
      expect(response.statusCode, 200);
      final body = await readBody(response);
      final data = jsonDecode(body) as Map<String, dynamic>;
      expect(data['networks'], isA<List>());
    });

    test('POST /api/wifi/connect returns JSON with success field', () async {
      final response = await post('/api/wifi/connect',
          body: jsonEncode({'ssid': 'TestNet', 'password': 'secret'}),
          headers: authHeaders);
      // On Windows/non-Linux the connect returns false → 500
      expect([200, 500], contains(response.statusCode));
      final body = await readBody(response);
      final data = jsonDecode(body) as Map<String, dynamic>;
      expect(data.containsKey('success'), true);
    });

    // --- Update status endpoint ---

    test('GET /api/update/status returns version info', () async {
      final response = await get('/api/update/status',
          headers: authHeaders);
      expect(response.statusCode, 200);
      final body = await readBody(response);
      final data = jsonDecode(body) as Map<String, dynamic>;
      expect(data.containsKey('currentVersion'), true);
      expect(data.containsKey('autoUpdate'), true);
    });

    group('update routes', () {
      Future<void> restart({
        required bool android,
        List<List<String>>? calls,
        AppUpdater? appUpdater,
      }) async {
        await server.stop();
        server = LocalApiServer(
          displayModeService: displayService,
          configNotifier: configNotifier,
          android: android,
          appUpdater: appUpdater,
          installedVersion: () async => '1.21.0',
          updateService: _FixedUpdateService(const UpdateInfo(
              version: '1.22.0', bundleUrl: 'u', tagName: 'v1.22.0')),
          runProcess: (exe, args) async {
            calls?.add([exe, ...args]);
            return ProcessResult(0, 0, 'started', '');
          },
        );
        port = await server.start(port: 0);
      }

      test('the Pi status reports only version and auto-update', () async {
        await restart(android: false);
        final data = jsonDecode(await readBody(
                await get('/api/update/status', headers: authHeaders)))
            as Map<String, dynamic>;
        expect(data, {'currentVersion': '1.21.0', 'autoUpdate': true});
      });

      test('the Pi apply still starts hearth-updater.service', () async {
        final calls = <List<String>>[];
        await restart(android: false, calls: calls);
        final res =
            await post('/api/update/apply', body: '{}', headers: authHeaders);
        expect(res.statusCode, 200);
        final data = jsonDecode(await readBody(res)) as Map<String, dynamic>;
        expect(data, {'success': true, 'output': 'started', 'error': ''});
        expect(calls, [
          ['sudo', 'systemctl', 'start', 'hearth-updater.service'],
        ]);
      });

      test('Android status adds the latest release and updater state',
          () async {
        final updater = AppUpdater(
            checkForUpdate: () async => null, installer: _NoInstaller());
        await restart(android: true, appUpdater: updater);
        final data = jsonDecode(await readBody(
                await get('/api/update/status', headers: authHeaders)))
            as Map<String, dynamic>;
        expect(data['currentVersion'], '1.21.0');
        expect(data['latestVersion'], '1.22.0');
        expect(data['updateAvailable'], true);
        expect((data['state'] as Map)['phase'], 'idle');
        updater.dispose();
      });

      test('Android apply reports where it stopped and never runs sudo',
          () async {
        final calls = <List<String>>[];
        final updater = AppUpdater(
          checkForUpdate: () async => const UpdateInfo(
              version: '1.22.0', bundleUrl: 'u', tagName: 'v1.22.0'),
          installedVersion: () async => '1.21.0',
          installer: _NoInstaller(),
        );
        await restart(android: true, calls: calls, appUpdater: updater);
        final res =
            await post('/api/update/apply', body: '{}', headers: authHeaders);
        expect(res.statusCode, 409);
        final data = jsonDecode(await readBody(res)) as Map<String, dynamic>;
        expect(data['state'], 'needsPermission');
        expect(data['message'], contains('install unknown apps'));
        expect(calls, isEmpty);
        updater.dispose();
      });
    });

    // --- Notify endpoint ---

    group('notify endpoint', () {
      late NotificationService notifications;

      setUp(() async {
        await server.stop();
        notifications = NotificationService(playChime: (_) async {});
        server = LocalApiServer(
          displayModeService: displayService,
          configNotifier: configNotifier,
          notificationService: notifications,
        );
        port = await server.start(port: 0);
      });

      tearDown(() => notifications.dispose());

      test('POST /api/notify ingests a normalized card', () async {
        final r = await post('/api/notify',
            body: jsonEncode({
              'title': 'Laundry',
              'message': 'Cycle finished',
              'priority': 'info',
            }),
            headers: authHeaders);
        expect(r.statusCode, 200);
        final json = jsonDecode(await readBody(r)) as Map<String, dynamic>;
        expect(json['status'], 'ok');
        expect(notifications.notifications, hasLength(1));
        final n = notifications.notifications.single;
        expect(n.title, 'Laundry');
        expect(n.body, 'Cycle finished');
        expect(n.priority, NotificationPriority.info);
        expect(n.source, NotificationSource.ha);
      });

      test('POST /api/notify requires auth', () async {
        final r = await post('/api/notify',
            body: jsonEncode({'title': 'x'}));
        expect(r.statusCode, 401);
        expect(notifications.notifications, isEmpty);
      });

      test('POST /api/notify rejects a payload with no title/message', () async {
        final r = await post('/api/notify',
            body: jsonEncode({'priority': 'alert'}), headers: authHeaders);
        expect(r.statusCode, 400);
        expect(notifications.notifications, isEmpty);
      });

      test('POST /api/notify clear returns 200', () async {
        await post('/api/notify',
            body: jsonEncode({'title': 'Person', 'tag': 'door'}),
            headers: authHeaders);
        expect(notifications.notifications, hasLength(1));
        final r = await post('/api/notify',
            body: jsonEncode({'tag': 'door', 'clear': true}),
            headers: authHeaders);
        expect(r.statusCode, 200);
        expect(notifications.notifications, isEmpty);
      });

      test('POST /api/notify clear with no tag returns 400', () async {
        final r = await post('/api/notify',
            body: jsonEncode({'clear': true}), headers: authHeaders);
        expect(r.statusCode, 400);
      });

      test('POST /api/notify returns 503 when no service is wired', () async {
        // Swap back to a server built without a NotificationService.
        await server.stop();
        server = LocalApiServer(
          displayModeService: displayService,
          configNotifier: configNotifier,
        );
        port = await server.start(port: 0);
        final r = await post('/api/notify',
            body: jsonEncode({'title': 'x'}), headers: authHeaders);
        expect(r.statusCode, 503);
      });
    });

    // --- Capture endpoints ---

    group('capture endpoints', () {
      late Directory tempDir;
      late CaptureService captureService;
      late ProviderContainer container;
      late int nextNow;

      setUp(() async {
        tempDir =
            await Directory.systemTemp.createTemp('hearth_api_capture_');
        nextNow = 0;
        captureService = CaptureService(
          capturesDir: tempDir,
          takeScreenshotFn: (path) async =>
              File(path).writeAsBytes([0x89, 0x50, 0x4E, 0x47]), // PNG magic
          spawnRecordingFn: (path) async {
            await File(path).writeAsBytes([0x00, 0x00, 0x00, 0x18]);
            return _TestRecording();
          },
          now: () =>
              DateTime(2026, 4, 21, 14, 30, nextNow++),
        );
        // Capture tools are gated behind HubConfig.captureToolsEnabled — the
        // plugin routes return 404 when it's false. Flip it on so these tests
        // exercise the real endpoint behavior.
        await configNotifier
            .update((c) => c.copyWith(captureToolsEnabled: true));

        // Capture lives in the CapturePlugin now; its routes reach the service
        // via readProvider, so override captureServiceProvider and wire the
        // plugin through the full LocalApiServer request stack.
        container = ProviderContainer(overrides: [
          captureServiceProvider.overrideWith((ref) => captureService),
        ]);
        await server.stop();
        server = LocalApiServer(
          displayModeService: displayService,
          configNotifier: configNotifier,
          readProvider: container.read,
          plugins: [CapturePlugin()],
        );
        port = await server.start(port: 0);
      });

      tearDown(() async {
        await captureService.dispose();
        await tempDir.delete(recursive: true);
        container.dispose();
      });

      test('POST /api/plugin/hearth.capture/screenshot creates a file', () async {
        final r = await post('/api/plugin/hearth.capture/screenshot',
            body: '', headers: authHeaders);
        expect(r.statusCode, 200);
        final json = jsonDecode(await readBody(r)) as Map<String, dynamic>;
        expect(json['filename'],
            matches(RegExp(r'^hearth-\d{8}-\d{6}\.png$')));
        expect(await File('${tempDir.path}/${json['filename']}').exists(),
            true);
      });

      test('POST /api/plugin/hearth.capture/recording/start then /stop', () async {
        final startResp = await post('/api/plugin/hearth.capture/recording/start',
            body: '', headers: authHeaders);
        expect(startResp.statusCode, 200);
        final startJson =
            jsonDecode(await readBody(startResp)) as Map<String, dynamic>;
        expect(startJson['filename'],
            matches(RegExp(r'^hearth-\d{8}-\d{6}\.mp4$')));

        final stopResp = await post('/api/plugin/hearth.capture/recording/stop',
            body: '', headers: authHeaders);
        expect(stopResp.statusCode, 200);
        final stopJson =
            jsonDecode(await readBody(stopResp)) as Map<String, dynamic>;
        expect(stopJson['filename'], startJson['filename']);
        expect(stopJson['sizeBytes'], greaterThan(0));
      });

      test('POST /api/plugin/hearth.capture/recording/start twice returns 409', () async {
        final first = await post('/api/plugin/hearth.capture/recording/start',
            body: '', headers: authHeaders);
        expect(first.statusCode, 200);
        final second = await post('/api/plugin/hearth.capture/recording/start',
            body: '', headers: authHeaders);
        expect(second.statusCode, 409);
      });

      test('POST /api/plugin/hearth.capture/recording/stop with no active returns 400',
          () async {
        final r = await post('/api/plugin/hearth.capture/recording/stop',
            body: '', headers: authHeaders);
        expect(r.statusCode, 400);
      });

      test('GET /api/plugin/hearth.capture/list enumerates captures and ignores garbage',
          () async {
        await post('/api/plugin/hearth.capture/screenshot',
            body: '', headers: authHeaders);
        await post('/api/plugin/hearth.capture/screenshot',
            body: '', headers: authHeaders);
        // Drop a malformed file — must be ignored.
        await File('${tempDir.path}/garbage.png').writeAsBytes([0]);

        final r = await get('/api/plugin/hearth.capture/list', headers: authHeaders);
        expect(r.statusCode, 200);
        final list = jsonDecode(await readBody(r)) as List<dynamic>;
        expect(list, hasLength(2));
        for (final entry in list) {
          final m = entry as Map<String, dynamic>;
          expect(m['filename'],
              matches(RegExp(r'^hearth-\d{8}-\d{6}\.png$')));
          expect(m['type'], 'png');
        }
      });

      test('GET /api/plugin/hearth.capture/file?name=... streams the file bytes',
          () async {
        final screenshotResp = await post('/api/plugin/hearth.capture/screenshot',
            body: '', headers: authHeaders);
        final name = (jsonDecode(await readBody(screenshotResp))
            as Map<String, dynamic>)['filename'] as String;

        final r = await get('/api/plugin/hearth.capture/file?name=$name',
            headers: authHeaders);
        expect(r.statusCode, 200);
        final bytes = await r.fold<List<int>>(
            [], (acc, chunk) => acc..addAll(chunk));
        expect(bytes, [0x89, 0x50, 0x4E, 0x47]);
      });

      test('GET /api/plugin/hearth.capture/file rejects invalid names with 400',
          () async {
        final r = await get('/api/plugin/hearth.capture/file?name=../etc/passwd',
            headers: authHeaders);
        expect(r.statusCode, 400);
      });

      test('GET /api/plugin/hearth.capture/file returns 404 when file missing', () async {
        final r = await get(
            '/api/plugin/hearth.capture/file?name=hearth-99999999-999999.png',
            headers: authHeaders);
        expect(r.statusCode, 404);
      });

      test(
          'GET /api/plugin/hearth.capture/file accepts session cookie instead of Bearer',
          () async {
        // First screenshot via Bearer.
        final screenshotResp = await post('/api/plugin/hearth.capture/screenshot',
            body: '', headers: authHeaders);
        final name = (jsonDecode(await readBody(screenshotResp))
            as Map<String, dynamic>)['filename'] as String;

        // Now unlock a web session.
        final pin = server.webPin;
        final authResp =
            await post('/auth/pin', body: jsonEncode({'pin': pin}));
        final setCookie = authResp.headers['set-cookie']!.first;
        final match =
            RegExp(r'hearth_session=(\w+)').firstMatch(setCookie);
        final cookie = 'hearth_session=${match!.group(1)}';

        final r = await get('/api/plugin/hearth.capture/file?name=$name',
            headers: {'Cookie': cookie});
        expect(r.statusCode, 200,
            reason: 'Session cookie must be accepted on /api/plugin/hearth.capture/file');
      });

      test('DELETE /api/plugin/hearth.capture/file?name=... removes the file', () async {
        final screenshotResp = await post('/api/plugin/hearth.capture/screenshot',
            body: '', headers: authHeaders);
        final name = (jsonDecode(await readBody(screenshotResp))
            as Map<String, dynamic>)['filename'] as String;

        final r = await delete('/api/plugin/hearth.capture/file?name=$name',
            headers: authHeaders);
        expect(r.statusCode, 200);
        expect(await File('${tempDir.path}/$name').exists(), false);
      });

      test('POST /api/plugin/hearth.capture/indicator-config updates HubConfig',
          () async {
        final r = await post('/api/plugin/hearth.capture/indicator-config',
            body: jsonEncode({
              'enabled': true,
              'radius': 55.0,
              'style': 'trail',
            }),
            headers: authHeaders);
        expect(r.statusCode, 200);
        expect(configNotifier.state.touchIndicator.enabled, true);
        expect(configNotifier.state.touchIndicator.radius, 55.0);
        expect(configNotifier.state.touchIndicator.style,
            TouchIndicatorStyle.trail);
        // Unchanged fields keep prior values.
        expect(configNotifier.state.touchIndicator.fadeMs, 600);
      });

      test('GET /api/plugin/hearth.capture/indicator-config returns current state',
          () async {
        configNotifier.state = const HubConfig(
          apiKey: testApiKey,
          captureToolsEnabled: true,
          touchIndicator: TouchIndicatorConfig(
            enabled: true,
            radius: 50.0,
          ),
        );
        final r = await get('/api/plugin/hearth.capture/indicator-config',
            headers: authHeaders);
        expect(r.statusCode, 200);
        final json = jsonDecode(await readBody(r)) as Map<String, dynamic>;
        expect(json['enabled'], true);
        expect(json['radius'], 50.0);
      });

      // Helper: unlock a web session and return its cookie header.
      Future<String> sessionCookie() async {
        final pin = server.webPin;
        final authResp =
            await post('/auth/pin', body: jsonEncode({'pin': pin}));
        final setCookie = authResp.headers['set-cookie']!.first;
        final match = RegExp(r'hearth_session=(\w+)').firstMatch(setCookie);
        return 'hearth_session=${match!.group(1)}';
      }

      test('web portal renders the Capture panel when enabled', () async {
        final cookie = await sessionCookie();
        // The Capture panel is the full interactive tools.
        final r = await get('/?panel=hearth.capture',
            headers: {'Cookie': cookie});
        expect(r.statusCode, 200);
        final body = await readBody(r);
        expect(body, contains('Capture'));
        expect(body, contains('Take Screenshot'));
        expect(body, contains('Touch Indicator'));
      });

      test('legacy /capture route is gone (404 even with a session)',
          () async {
        final cookie = await sessionCookie();
        final r = await get('/capture', headers: {'Cookie': cookie});
        expect(r.statusCode, 404);
      });

      test('Capture sidebar entry hidden on web when disabled', () async {
        await configNotifier
            .update((c) => c.copyWith(captureToolsEnabled: false));
        final cookie = await sessionCookie();
        // Asking for the hidden panel falls back to the first visible plugin —
        // none of the Capture panel chrome renders.
        final r = await get('/?panel=hearth.capture',
            headers: {'Cookie': cookie});
        expect(r.statusCode, 200);
        final body = await readBody(r);
        expect(body, isNot(contains('Take Screenshot')));
      });

      test('all capture routes 404 when captureToolsEnabled is false', () async {
        await configNotifier
            .update((c) => c.copyWith(captureToolsEnabled: false));

        final screenshot = await post('/api/plugin/hearth.capture/screenshot',
            body: '', headers: authHeaders);
        expect(screenshot.statusCode, 404);

        final list = await get('/api/plugin/hearth.capture/list', headers: authHeaders);
        expect(list.statusCode, 404);

        final indicator =
            await get('/api/plugin/hearth.capture/indicator-config', headers: authHeaders);
        expect(indicator.statusCode, 404);
      });
    });

  });
}

class _TestRecording implements RecordingProcess {
  final _exit = Completer<int>();
  @override
  Future<int> get exitCode => _exit.future;
  @override
  void stop() {
    if (!_exit.isCompleted) _exit.complete(0);
  }
  @override
  void kill() {
    if (!_exit.isCompleted) _exit.complete(-9);
  }
}

/// [HubConfigNotifier] subclass that skips disk persistence so tests can
/// call [update] without initialising the Flutter binding or path_provider.
class _MemoryHubConfigNotifier extends HubConfigNotifier {
  @override
  Future<void> update(HubConfig Function(HubConfig) updater) async {
    state = updater(state);
  }
}

class _FixedUpdateService extends UpdateService {
  final UpdateInfo? _latest;
  _FixedUpdateService(this._latest);

  @override
  Future<UpdateInfo?> checkForUpdate() async => _latest;
}

/// An installer without the "Install unknown apps" grant.
class _NoInstaller implements AppInstaller {
  @override
  Future<bool> canInstall() async => false;

  @override
  Future<void> openInstallSettings() async {}

  @override
  Future<void> install(String apkPath) async {}

  @override
  Stream<InstallResult> get results => const Stream.empty();
}
