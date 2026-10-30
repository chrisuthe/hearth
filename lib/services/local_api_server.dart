import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart' show LicenseRegistry;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../app/screen_navigator.dart';
import '../modules/alarm_clock/alarm_models.dart';
import '../modules/alarm_clock/alarm_service.dart';
import '../utils/logger.dart';
import '../config/hub_config.dart';
import 'notification_service.dart';
import '../plugins/plugin_registry.dart';
import '../plugins/hearth_plugin.dart';
import '../plugins/framework/plugin_router.dart';
import '../plugins/framework/web_assets.dart' show hearthFaviconLink;
import '../plugins/framework/web_renderer.dart';
import 'display_mode_service.dart';
import 'third_party_licenses.dart';
import 'timezone_service.dart';
import 'wifi_service.dart';
import 'app_updater.dart';
import 'installed_version.dart';
import 'update_service.dart';

/// Minimal HTTP server for external device control and configuration.
///
/// Runs on port 8090 by default. All /api/* endpoints require a Bearer
/// token matching the auto-generated apiKey in HubConfig. The config
/// page at / is unauthenticated so a fresh kiosk can be set up from
/// any browser on the LAN.
///
/// Endpoints:
///   GET  /                 — config web page (unauthenticated)
///   GET  /api/config       — read config (secrets redacted)
///   POST /api/config       — update config fields
///   POST /api/display-mode — set night/day mode
///   GET  /api/display-mode — query current mode
///   GET  /api/screen       — current screen and the swipe row's screens
///   POST /api/screen       — show a screen by id or name ({"screen": "calendar"})
///   POST /api/notify       — surface a notification card (HA rest_command)
///   GET  /api/wifi/scan    — scan for WiFi networks
///   POST /api/wifi/connect — connect to a WiFi network
///   GET  /api/update/status — current version and auto-update setting
///                             (Android adds the latest release and updater state)
///   GET  /api/alarms        — list all alarms
///   POST /api/alarms        — create or update an alarm
///   DELETE /api/alarms?id=x — delete an alarm
class LocalApiServer {
  final DisplayModeService _displayModeService;
  final HubConfigNotifier _configNotifier;
  final TimezoneService _timezoneService;
  final WifiService _wifiService;
  final UpdateService _updateService;
  final AlarmService? _alarmService;
  final NotificationService? _notificationService;
  final ScreenNavigator? _screenNavigator;

  /// Android routes the update endpoints to [_appUpdater] instead of
  /// `hearth-updater.service`.
  final bool _android;
  final AppUpdater? _appUpdater;
  final Future<String> Function() _installedVersion;
  final Future<ProcessResult> Function(String, List<String>) _runProcess;

  /// Reads service providers for plugin routes. Production wires `ref.read`
  /// (see [localApiServerProvider]); null in constructions made without a
  /// Riverpod `ref`, where [PluginRequest.readProvider] then throws.
  final ProviderReader? _readProvider;

  /// Plugins whose HTTP routes are registered in [start]. Defaults to the
  /// first-party registry; overridable so tests can drive a bespoke route
  /// through the full request stack.
  final List<HearthPlugin> _plugins;

  HttpServer? _server;

  /// Loads the bundled MaterialIcons font bytes for the web portal. Defaults
  /// to reading Flutter's bundled asset via [rootBundle]; injectable so tests
  /// can supply bytes without a Flutter binding.
  final Future<List<int>> Function() _loadIconFont;

  /// Cached font bytes — the asset never changes for a given build, so load
  /// once and reuse for every `/assets/material-icons.otf` request.
  List<int>? _iconFontBytes;

  static const int _maxBodySize = 64 * 1024; // 64 KB

  /// A whole backup (webviews, people, calendars, Sendspin trust records)
  /// can outgrow [_maxBodySize]; only the restore route gets this cap.
  static const int _maxRestoreBodySize = 4 * 1024 * 1024; // 4 MB
  static const _restorePath = '/api/plugin/hearth.system/restore';

  /// Plugin routes that need the PIN session and refuse the bearer key. The
  /// key is handed to Home Assistant `rest_command`s, so it must not be able
  /// to download every secret or restore over the device's identity.
  static const _sessionOnlyPluginPaths = {
    '/api/plugin/hearth.system/backup',
    _restorePath,
  };

  /// 4-digit PIN displayed on the kiosk Settings screen.
  /// Users must enter this PIN in the web portal to gain access.
  final String _webPin;
  String get webPin => _webPin;

  /// Active session tokens granted after successful PIN entry.
  final Set<String> _activeSessions = {};

  /// Router for plugin-contributed `/api/plugin/<id>/...` routes.
  /// Initialized in [start] after the HTTP server binds.
  late final PluginRouter _pluginRouter;

  LocalApiServer({
    required DisplayModeService displayModeService,
    required HubConfigNotifier configNotifier,
    TimezoneService? timezoneService,
    WifiService? wifiService,
    UpdateService? updateService,
    AlarmService? alarmService,
    NotificationService? notificationService,
    ScreenNavigator? screenNavigator,
    bool? android,
    AppUpdater? appUpdater,
    Future<String> Function()? installedVersion,
    Future<ProcessResult> Function(String, List<String>)? runProcess,
    ProviderReader? readProvider,
    List<HearthPlugin>? plugins,
    String? webPin,
    Future<List<int>> Function()? loadIconFont,
  })  : _displayModeService = displayModeService,
        _configNotifier = configNotifier,
        _timezoneService = timezoneService ?? TimezoneService(),
        _wifiService = wifiService ?? WifiService(),
        _updateService = updateService ?? UpdateService(),
        _alarmService = alarmService,
        _notificationService = notificationService,
        _screenNavigator = screenNavigator,
        _android = android ?? Platform.isAndroid,
        _appUpdater = appUpdater,
        _installedVersion = installedVersion ??
            (() => readInstalledVersion(android: android)),
        _runProcess = runProcess ?? Process.run,
        _readProvider = readProvider,
        _plugins = plugins ?? firstPartyPlugins,
        _loadIconFont = loadIconFont ?? _loadBundledIconFont,
        _webPin = webPin ?? (Random.secure().nextInt(9000) + 1000).toString();

  Future<int> start({int port = 8090}) async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _pluginRouter = PluginRouter();
    for (final plugin in _plugins) {
      _pluginRouter.register(plugin.id);
      plugin.registerHttpRoutes(_pluginRouter);
    }
    _server!.listen(_handleRequest);
    return _server!.port;
  }

  /// Generates a random 32-character session token.
  static String _generateSessionToken() {
    final rng = Random.secure();
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(32, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  /// Checks whether the request carries a valid session cookie.
  bool _checkSession(HttpRequest request) {
    final cookieHeader = request.headers.value('cookie');
    if (cookieHeader == null) return false;
    // Parse cookies: "name=value; name2=value2"
    for (final part in cookieHeader.split(';')) {
      final trimmed = part.trim();
      if (trimmed.startsWith('hearth_session=')) {
        final token = trimmed.substring('hearth_session='.length);
        return _activeSessions.contains(token);
      }
    }
    return false;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      // Reject CORS preflight requests — the kiosk API is same-origin only.
      if (request.method == 'OPTIONS') {
        request.response.statusCode = 403;
        await request.response.close();
        return;
      }

      final path = request.uri.path;

      // --- PIN auth endpoint (unauthenticated) ---
      if (path == '/auth/pin' && request.method == 'POST') {
        await _handlePinAuth(request);
        return;
      }

      // --- Self-hosted Material Icons font (unauthenticated, non-sensitive) ---
      // The @font-face request the settings page issues carries no auth, and
      // the font is just a public glyph file, so serve it without a session.
      if (path == '/assets/material-icons.otf' && request.method == 'GET') {
        await _serveIconFont(request);
        return;
      }

      if (path == '/') {
        if (_checkSession(request)) {
          await _serveConfigPage(request);
        } else {
          await _servePinPage(request);
        }
      } else if (path == '/logs') {
        if (_checkSession(request)) {
          await _serveLogsPage(request);
        } else {
          await _servePinPage(request);
        }
      } else if (path == '/licenses') {
        if (_checkSession(request)) {
          await _serveLicensesPage(request);
        } else {
          await _servePinPage(request);
        }
      } else if (path == '/api/session/key' && request.method == 'GET') {
        if (!_checkSession(request)) {
          request.response.statusCode = 401;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': 'unauthorized'}));
          await request.response.close();
          return;
        }
        await _handleSessionKey(request);
      } else if (path == '/api/logs' && request.method == 'GET') {
        if (!_checkAuth(request)) return;
        await _handleGetLogs(request);
      } else if (path == '/api/system/stats' && request.method == 'GET') {
        if (!_checkAuth(request)) return;
        await _handleSystemStats(request);
      } else if (path.startsWith('/api/plugin/')) {
        // The Capture plugin's file route backs <a href> downloads, so it must
        // accept the web session cookie as well as a bearer token. The generic
        // plugin dispatch is bearer-only; every other plugin route stays that
        // way.
        if (path == '/api/plugin/hearth.capture/file') {
          if (!_checkAuthOrSession(request)) return;
        } else if (_sessionOnlyPluginPaths.contains(path)) {
          if (!_checkSession(request)) {
            request.response.statusCode = 401;
            request.response.headers.contentType = ContentType.json;
            request.response.write(jsonEncode({'error': 'unauthorized'}));
            await request.response.close();
            return;
          }
        } else {
          if (!_checkAuth(request)) return;
        }
        final match = _pluginRouter.match(request.method, path);
        if (match == null) {
          request.response.statusCode = 404;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': 'plugin route not found'}));
          await request.response.close();
          return;
        }
        Map<String, dynamic> body = {};
        if ((request.method == 'POST' || request.method == 'PUT') &&
            request.contentLength > 0) {
          try {
            body = await _readJsonBody(request,
                maxSize: path == _restorePath ? _maxRestoreBodySize : _maxBodySize);
          } catch (e) {
            // _readJsonBody already wrote a 413 for an oversized body.
            if (e is! FormatException ||
                e.message != 'Request body too large') {
              request.response.statusCode = 400;
              request.response.headers.contentType = ContentType.json;
              request.response.write(jsonEncode({'error': 'invalid JSON body'}));
              await request.response.close();
            }
            return;
          }
        }
        await match.handler(PluginRequest(
          raw: request,
          body: body,
          pathParams: match.params,
          config: _configNotifier.current,
          configNotifier: _configNotifier,
          readProvider: _readProvider,
        ));
        return;
      } else if (path.startsWith('/api/')) {
        if (!_checkAuth(request)) return;
        if (path == '/api/config') {
          if (request.method == 'GET') {
            await _handleGetConfig(request);
          } else if (request.method == 'POST') {
            await _handlePostConfig(request);
          } else {
            request.response.statusCode = 405;
            await request.response.close();
          }
        } else if (path == '/api/display-mode') {
          if (request.method == 'POST') {
            await _handleSetDisplayMode(request);
          } else if (request.method == 'GET') {
            await _handleGetDisplayMode(request);
          } else {
            request.response.statusCode = 405;
            await request.response.close();
          }
        } else if (path == '/api/screen') {
          if (request.method == 'POST') {
            await _handleSetScreen(request);
          } else if (request.method == 'GET') {
            await _handleGetScreen(request);
          } else {
            request.response.statusCode = 405;
            await request.response.close();
          }
        } else if (path == '/api/notify' && request.method == 'POST') {
          await _handleNotify(request);
        } else if (path == '/api/wifi/scan' && request.method == 'GET') {
          await _handleWifiScan(request);
        } else if (path == '/api/wifi/connect' && request.method == 'POST') {
          await _handleWifiConnect(request);
        } else if (path == '/api/update/status' && request.method == 'GET') {
          await _handleUpdateStatus(request);
        } else if (path == '/api/update/check' && request.method == 'POST') {
          await _handleUpdateCheck(request);
        } else if (path == '/api/update/apply' && request.method == 'POST') {
          await _handleUpdateApply(request);
        } else if (path == '/api/alarms') {
          if (request.method == 'GET') {
            await _handleGetAlarms(request);
          } else if (request.method == 'POST') {
            await _handlePostAlarm(request);
          } else if (request.method == 'DELETE') {
            await _handleDeleteAlarm(request);
          } else {
            request.response.statusCode = 405;
            await request.response.close();
          }
        } else {
          request.response.statusCode = 404;
          request.response.write(jsonEncode({'error': 'not found'}));
          await request.response.close();
        }
      } else {
        request.response.statusCode = 404;
        request.response.write(jsonEncode({'error': 'not found'}));
        await request.response.close();
      }
    } catch (e) {
      Log.e('API', 'Request handler error: $e');
      try {
        request.response.statusCode = 500;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'internal server error'}));
        await request.response.close();
      } catch (_) {
        // Response may already be closed or broken — nothing more we can do.
      }
    }
  }

  /// Validates the Bearer token against the stored API key.
  /// Returns true if authorized, false if rejected (response already sent).
  bool _checkAuth(HttpRequest request) {
    final apiKey = _configNotifier.current.apiKey;
    final authHeader = request.headers.value('authorization');
    final token = authHeader != null && authHeader.startsWith('Bearer ')
        ? authHeader.substring(7)
        : null;

    if (token != apiKey) {
      request.response.statusCode = 401;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'unauthorized'}));
      request.response.close();
      return false;
    }
    return true;
  }

  /// Reads and decodes a JSON request body with size limit enforcement.
  /// Rejects early if Content-Length exceeds the limit, then streams with
  /// a byte counter to guard against chunked transfers that lie about length.
  Future<Map<String, dynamic>> _readJsonBody(HttpRequest request,
      {int maxSize = _maxBodySize}) async {
    if (request.contentLength > maxSize) {
      request.response.statusCode = 413;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'request body too large'}));
      await request.response.close();
      throw const FormatException('Request body too large');
    }
    final chunks = <int>[];
    await for (final chunk in request) {
      chunks.addAll(chunk);
      if (chunks.length > maxSize) {
        request.response.statusCode = 413;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'request body too large'}));
        await request.response.close();
        throw const FormatException('Request body too large');
      }
    }
    final body = utf8.decode(chunks);
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// Reads raw request body as a string with size limit enforcement.
  /// Returns null and sends a 413 response if the body is too large.
  Future<String?> _readBody(HttpRequest request) async {
    if (request.contentLength > _maxBodySize) {
      request.response.statusCode = 413;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'request body too large'}));
      await request.response.close();
      return null;
    }
    final chunks = <int>[];
    await for (final chunk in request) {
      chunks.addAll(chunk);
      if (chunks.length > _maxBodySize) {
        request.response.statusCode = 413;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'error': 'request body too large'}));
        await request.response.close();
        return null;
      }
    }
    return utf8.decode(chunks);
  }

  // --- PIN auth ---

  Future<void> _handlePinAuth(HttpRequest request) async {
    final json = await _readJsonBody(request);
    final pin = json['pin'] as String?;
    if (pin == _webPin) {
      final token = _generateSessionToken();
      _activeSessions.add(token);
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      request.response.headers.add(
        'Set-Cookie',
        'hearth_session=$token; HttpOnly; SameSite=Strict; Max-Age=86400; Path=/',
      );
      request.response.write(jsonEncode({'status': 'ok'}));
      await request.response.close();
    } else {
      request.response.statusCode = 401;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'wrong pin'}));
      await request.response.close();
    }
  }

  /// Returns the API key to authenticated web sessions so JS can call /api/*.
  Future<void> _handleSessionKey(HttpRequest request) async {
    final apiKey = _configNotifier.current.apiKey;
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'apiKey': apiKey}));
    await request.response.close();
  }

  // --- Config endpoints ---

  Future<void> _handleGetConfig(HttpRequest request) async {
    final json = _configNotifier.current.toJson();
    // Redact secrets — tokens are write-only from the API's perspective.
    const secretFields = ['apiKey', 'haToken', 'immichApiKey', 'musicAssistantToken', 'frigatePassword', 'mealieToken', 'giteaApiToken', 'mqttPassword', 'plexAuthToken'];
    for (final field in secretFields) {
      final value = json[field] as String? ?? '';
      json[field] = value.isEmpty ? '' : '••••••••';
    }
    // An ICS URL can carry a secret (e.g. Google's private iCal address).
    json['calendarSources'] = [
      for (final s in _configNotifier.current.calendarSources)
        {
          ...s.toJson(),
          if (s.url.isNotEmpty) 'url': _redactedMarker,
        },
    ];
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(json));
    await request.response.close();
  }

  /// Puts back each stored ICS URL that a client echoed as the redaction
  /// marker, matched by source id. An entry whose marker matches no stored
  /// source is dropped: the marker is never a real URL.
  static List<dynamic> _restoreCalendarUrls(List<dynamic> sources, HubConfig c) {
    final stored = {for (final s in c.calendarSources) s.id: s.url};
    final restored = <dynamic>[];
    for (final entry in sources) {
      if (entry is Map && entry['url'] == _redactedMarker) {
        final url = stored[entry['id']];
        if (url == null || url.isEmpty) continue;
        restored
            .add(<String, dynamic>{...entry.cast<String, dynamic>(), 'url': url});
      } else {
        restored.add(entry);
      }
    }
    return restored;
  }

  static const _redactedMarker = '\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022';

  /// Config keys that must never be written through the web API, regardless
  /// of what a client posts:
  ///   * [apiKey] \u2014 the bearer token itself; overwriting it would brick web
  ///     and API access (and it's redacted on GET).
  ///   * [dlnaUuid] \u2014 internal UPnP device identity, app-seeded when the
  ///     DLNA renderer is first enabled.
  ///   * [plexClientId] \u2014 internal Plex device identity, app-seeded when the
  ///     Plex player is first enabled.
  ///   * [plexAuthToken] \u2014 plex.tv token from on-device PIN pairing.
  ///   * [mqttDeviceId] \u2014 MQTT/HA device identity, app-seeded when a
  ///     broker is first configured; changing it orphans the HA device.
  ///   * [currentVersion] \u2014 managed by the updater, not user-editable.
  ///   * [setupComplete] \u2014 first-run flow state.
  static const _webReadOnlyConfigKeys = {
    'apiKey',
    'dlnaUuid',
    'plexClientId',
    'plexAuthToken',
    'mqttDeviceId',
    'currentVersion',
    'setupComplete',
    'voiceSatelliteMac',
  };

  /// Coerce an incoming JSON value to match the runtime type of the existing
  /// config value. The web auto-save helper (`hearth.js`) posts numbers and
  /// enum selections as strings (text / select / range inputs), so without
  /// this an int or double field would be silently dropped or corrupted on
  /// save. Booleans arrive as real bools from checkboxes. List/Map values and
  /// string fields pass through unchanged. Falls back to [existing] when a
  /// value can't be parsed so a malformed post can't blank a typed field.
  static dynamic _coerceConfigValue(dynamic incoming, dynamic existing) {
    if (incoming == null) return null;
    if (existing is bool) {
      if (incoming is bool) return incoming;
      if (incoming is String) return incoming == 'true' || incoming == '1';
      return existing;
    }
    if (existing is int) {
      if (incoming is int) return incoming;
      if (incoming is num) return incoming.round();
      if (incoming is String) {
        return int.tryParse(incoming) ??
            double.tryParse(incoming)?.round() ??
            existing;
      }
      return existing;
    }
    if (existing is double) {
      if (incoming is num) return incoming.toDouble();
      if (incoming is String) return double.tryParse(incoming) ?? existing;
      return existing;
    }
    // String, List, Map, or a null-typed existing value: pass the JSON value
    // straight through; HubConfig.fromJson applies the final cast.
    return incoming;
  }

  Future<void> _handlePostConfig(HttpRequest request) async {
    final json = await _readJsonBody(request);

    // Filter out redacted markers so clients cannot overwrite real secrets
    // with the placeholder value returned by GET /api/config.
    const secretFields = ['haToken', 'immichApiKey', 'musicAssistantToken', 'frigatePassword', 'mealieToken', 'giteaApiToken', 'mqttPassword', 'plexAuthToken'];
    for (final field in secretFields) {
      if (json[field] == _redactedMarker) {
        json.remove(field);
      }
    }

    // Generic, type-aware merge over HubConfig \u2014 mirrors the on-device write
    // path (HubConfig.fromJson({...toJson(), key: value})) so the web portal
    // and the kiosk save the same fields the same way. Unknown and read-only
    // keys are ignored; everything else is coerced to its declared type.
    await _configNotifier.update((c) {
      final current = c.toJson();
      final merged = Map<String, dynamic>.from(current);
      final sources = json['calendarSources'];
      if (sources is List) {
        json['calendarSources'] = _restoreCalendarUrls(sources, c);
      }
      for (final entry in json.entries) {
        final key = entry.key;
        if (!current.containsKey(key)) continue;
        if (_webReadOnlyConfigKeys.contains(key)) continue;
        merged[key] = _coerceConfigValue(entry.value, current[key]);
      }
      return HubConfig.fromJson(merged);
    });

    // Apply timezone change immediately on Linux.
    final tz = json['timezone'];
    if (tz is String && tz.isNotEmpty) {
      await _timezoneService.applyTimezone(tz);
    }

    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'status': 'saved'}));
    await request.response.close();
  }

  // --- Display mode endpoints ---

  Future<void> _handleSetDisplayMode(HttpRequest request) async {
    final json = await _readJsonBody(request);
    final modeStr = json['mode'] as String?;

    final mode = modeStr == 'night' ? DisplayMode.night : DisplayMode.day;
    _displayModeService.setModeFromApi(mode);

    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'mode': modeStr}));
    await request.response.close();
  }

  Future<void> _handleGetDisplayMode(HttpRequest request) async {
    final config = _configNotifier.current;
    final mode = _displayModeService.resolveMode(config: config);
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'mode': mode.name}));
    await request.response.close();
  }

  // --- Screen endpoints ---

  /// `GET /api/screen` — `{"screen": id, "index": n, "screens": [{id, name}]}`,
  /// screens in swipe order.
  Future<void> _handleGetScreen(HttpRequest request) async {
    final navigator = _screenNavigator;
    request.response.headers.contentType = ContentType.json;
    if (navigator == null) {
      request.response.statusCode = 503;
      request.response
          .write(jsonEncode({'error': 'screen control unavailable'}));
      await request.response.close();
      return;
    }
    final current = navigator.current;
    request.response.statusCode = 200;
    request.response.write(jsonEncode({
      'screen': current.id,
      'index': current.index,
      'screens': [
        for (final s in navigator.screens) {'id': s.id, 'name': s.name},
      ],
    }));
    await request.response.close();
  }

  /// `POST /api/screen` — body `{"screen": "<id or name>"}`. Shows that
  /// screen as a touch would, so the idle return to Home still applies.
  Future<void> _handleSetScreen(HttpRequest request) async {
    final navigator = _screenNavigator;
    if (navigator == null) {
      request.response.statusCode = 503;
      request.response.headers.contentType = ContentType.json;
      request.response
          .write(jsonEncode({'error': 'screen control unavailable'}));
      await request.response.close();
      return;
    }
    final json = await _readJsonBody(request);
    final requested = json['screen'];
    final screen = requested is String ? navigator.show(requested) : null;
    request.response.headers.contentType = ContentType.json;
    if (screen == null) {
      request.response.statusCode = requested is String ? 404 : 400;
      request.response.write(jsonEncode({
        'error': requested is String ? 'unknown screen' : 'screen required',
        'screens': [for (final s in navigator.screens) s.id],
      }));
      await request.response.close();
      return;
    }
    request.response.statusCode = 200;
    request.response.write(jsonEncode({'screen': screen.id}));
    await request.response.close();
  }

  // --- Notification ingest ---

  /// `POST /api/notify` — the HTTP fallback for non-MQTT setups (driven from
  /// HA via `rest_command`). Same JSON schema and normalize path
  /// (`NotificationService.ingestPayload`) as the MQTT `.../notify` topic.
  ///
  /// Body: {"title": "...", "message": "...", "priority": "alert"|"info",
  ///        "sticky": true|false, "source": "...", "source_label": "...",
  ///        "muted": true|false, "image": "...", "image_refresh": 3,
  ///        "camera": "...", "tag": "...", "timeout": 180} — one of
  ///        title/message required. {"tag": "...", "clear": true} closes
  ///        that card.
  Future<void> _handleNotify(HttpRequest request) async {
    final service = _notificationService;
    if (service == null) {
      request.response.statusCode = 503;
      request.response.headers.contentType = ContentType.json;
      request.response
          .write(jsonEncode({'error': 'notification service unavailable'}));
      await request.response.close();
      return;
    }
    final json = await _readJsonBody(request);
    final id = service.ingestPayload(json);
    if (id == null) {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response
          .write(jsonEncode({'error': 'title or message required'}));
      await request.response.close();
      return;
    }
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'status': 'ok', 'id': id}));
    await request.response.close();
  }

  // --- WiFi endpoints ---

  Future<void> _handleWifiScan(HttpRequest request) async {
    final networks = await _wifiService.scan();
    final connected = await _wifiService.activeConnection();
    request.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({
        'networks': networks.map((n) => {
          'ssid': n.ssid,
          'signal': n.signalStrength,
          'security': n.security,
          'isOpen': n.isOpen,
        }).toList(),
        'connected': connected,
      }));
    await request.response.close();
  }

  Future<void> _handleWifiConnect(HttpRequest request) async {
    final body = await _readBody(request);
    if (body == null) return;
    final data = jsonDecode(body) as Map<String, dynamic>;
    final ssid = data['ssid'] as String? ?? '';
    final password = data['password'] as String? ?? '';
    final success = password.isEmpty
        ? await _wifiService.connectOpen(ssid)
        : await _wifiService.connect(ssid, password);
    request.response
      ..statusCode = success ? 200 : 500
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'success': success}));
    await request.response.close();
  }

  Future<void> _handleUpdateStatus(HttpRequest request) async {
    final config = _configNotifier.current;
    final status = <String, dynamic>{
      'currentVersion': await _installedVersion(),
      'autoUpdate': config.autoUpdate,
    };
    if (_android) {
      final latest = await _updateService.checkForUpdate();
      status['latestVersion'] = latest?.version;
      status['updateAvailable'] =
          latest != null && latest.isNewerThan(status['currentVersion']);
      status['state'] = _appUpdater?.current.toJson();
    }
    request.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(status));
    await request.response.close();
  }

  Future<void> _handleUpdateCheck(HttpRequest request) async {
    final currentVersion = await _installedVersion();
    final latest = await _updateService.checkForUpdate();
    final available = latest != null && latest.isNewerThan(currentVersion);
    request.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({
        'currentVersion': currentVersion,
        'latestVersion': latest?.version,
        'updateAvailable': available,
        'bundleUrl': latest?.bundleUrl,
      }));
    await request.response.close();
  }

  Future<void> _handleUpdateApply(HttpRequest request) async {
    if (_android) return _handleAndroidUpdateApply(request);
    try {
      // Trigger the updater via systemd (runs as root with proper privileges)
      final result = await _runProcess('sudo', [
        'systemctl', 'start', 'hearth-updater.service',
      ]).timeout(const Duration(seconds: 30));
      request.response
        ..statusCode = result.exitCode == 0 ? 200 : 500
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'success': result.exitCode == 0,
          'output': result.stdout.toString(),
          'error': result.stderr.toString(),
        }));
    } catch (e) {
      request.response
        ..statusCode = 500
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'success': false, 'error': e.toString()}));
    }
    await request.response.close();
  }

  /// Runs the update as far as the system install prompt and reports where
  /// it stopped. The download happens inside the request, so the portal
  /// gets the outcome (or the reason it failed) in the response.
  Future<void> _handleAndroidUpdateApply(HttpRequest request) async {
    final updater = _appUpdater;
    final AppUpdateState state;
    if (updater == null) {
      state = const AppUpdateState(
          AppUpdatePhase.failed, 'Updater is not available on this build');
    } else if (updater.current.busy) {
      state = updater.current;
    } else {
      state = await updater.apply();
    }
    final statusCode = switch (state.phase) {
      AppUpdatePhase.waitingForConfirmation || AppUpdatePhase.upToDate => 200,
      AppUpdatePhase.failed => 500,
      _ => 409,
    };
    request.response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({
        'success': statusCode == 200,
        'state': state.phase.name,
        'message': state.message,
      }));
    await request.response.close();
  }

  // --- System stats ---

  Future<void> _handleSystemStats(HttpRequest request) async {
    try {
      // CPU: parse /proc/stat for usage, /sys/class/thermal for temp
      final cpuTemp = await _readFile('/sys/class/thermal/thermal_zone0/temp');
      final tempC = cpuTemp.isNotEmpty ? (int.tryParse(cpuTemp.trim()) ?? 0) / 1000.0 : null;

      final loadavg = await _readFile('/proc/loadavg');
      final loads = loadavg.split(' ');

      // Memory: parse /proc/meminfo
      final meminfo = await _readFile('/proc/meminfo');
      final memMap = <String, int>{};
      for (final line in meminfo.split('\n')) {
        final match = RegExp(r'(\w+):\s+(\d+)').firstMatch(line);
        if (match != null) memMap[match.group(1)!] = int.parse(match.group(2)!);
      }
      final totalMb = (memMap['MemTotal'] ?? 0) ~/ 1024;
      final availMb = (memMap['MemAvailable'] ?? 0) ~/ 1024;
      final usedMb = totalMb - availMb;

      // GPU: try vcgencmd (Pi-specific)
      String? gpuTemp;
      String? gpuMem;
      try {
        final gpuResult = await Process.run('vcgencmd', ['measure_temp']);
        if (gpuResult.exitCode == 0) {
          gpuTemp = RegExp(r'[\d.]+').firstMatch(gpuResult.stdout.toString())?.group(0);
        }
        final memResult = await Process.run('vcgencmd', ['get_mem', 'gpu']);
        if (memResult.exitCode == 0) {
          gpuMem = RegExp(r'\d+').firstMatch(memResult.stdout.toString())?.group(0);
        }
      } catch (_) {}

      // Uptime
      final uptime = await _readFile('/proc/uptime');
      final uptimeSecs = double.tryParse(uptime.split(' ').first) ?? 0;

      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'cpu': {
            'tempC': tempC,
            'load1m': loads.isNotEmpty ? loads[0] : null,
            'load5m': loads.length > 1 ? loads[1] : null,
            'load15m': loads.length > 2 ? loads[2] : null,
          },
          'memory': {
            'totalMb': totalMb,
            'usedMb': usedMb,
            'availableMb': availMb,
          },
          'gpu': {
            'tempC': gpuTemp != null ? double.tryParse(gpuTemp) : null,
            'memoryMb': gpuMem != null ? int.tryParse(gpuMem) : null,
          },
          'uptimeSeconds': uptimeSecs.round(),
        }));
    } catch (e) {
      request.response
        ..statusCode = 500
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'error': e.toString()}));
    }
    await request.response.close();
  }

  Future<String> _readFile(String path) async {
    try {
      return await File(path).readAsString();
    } catch (_) {
      return '';
    }
  }

  // --- Logs ---

  Future<void> _handleGetLogs(HttpRequest request) async {
    final lines = request.uri.queryParameters['lines'] ?? '100';
    try {
      final result = await Process.run('journalctl', [
        '-u', 'hearth.service',
        '--no-pager',
        '-n', lines,
        '--output', 'short-iso',
      ]);
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'logs': result.stdout.toString()}));
    } catch (e) {
      request.response
        ..statusCode = 500
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'error': e.toString()}));
    }
    await request.response.close();
  }

  Future<void> _serveLogsPage(HttpRequest request) async {
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.html;
    request.response.write(_logsPageHtml);
    await request.response.close();
  }

  Future<void> _serveLicensesPage(HttpRequest request) async {
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.html;
    request.response.write(await renderLicensesHtml(LicenseRegistry.licenses));
    await request.response.close();
  }

  // --- Alarms ---

  Future<void> _handleGetAlarms(HttpRequest request) async {
    final service = _alarmService;
    if (service == null) {
      request.response.statusCode = 503;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'alarm service unavailable'}));
      await request.response.close();
      return;
    }
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode(service.alarms.map((a) => a.toJson()).toList()),
    );
    await request.response.close();
  }

  Future<void> _handlePostAlarm(HttpRequest request) async {
    final service = _alarmService;
    if (service == null) {
      request.response.statusCode = 503;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'alarm service unavailable'}));
      await request.response.close();
      return;
    }
    try {
      final json = await _readJsonBody(request);
      final alarm = Alarm.fromJson(json);
      // Check if this alarm already exists (update) or is new (add).
      final existing = service.alarms.where((a) => a.id == alarm.id);
      if (existing.isNotEmpty) {
        service.updateAlarm(alarm);
      } else {
        service.addAlarm(alarm);
      }
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(alarm.toJson()));
      await request.response.close();
    } catch (e) {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'invalid alarm data'}));
      await request.response.close();
    }
  }

  Future<void> _handleDeleteAlarm(HttpRequest request) async {
    final service = _alarmService;
    if (service == null) {
      request.response.statusCode = 503;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'alarm service unavailable'}));
      await request.response.close();
      return;
    }
    final id = request.uri.queryParameters['id'];
    if (id == null || id.isEmpty) {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'missing id parameter'}));
      await request.response.close();
      return;
    }
    service.deleteAlarm(id);
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'status': 'ok'}));
    await request.response.close();
  }

  // --- Material Icons font ---

  /// Serves the bundled MaterialIcons font so the web portal can render plugin
  /// glyphs offline. Bytes are loaded once and cached.
  Future<void> _serveIconFont(HttpRequest request) async {
    try {
      final bytes = _iconFontBytes ??= await _loadIconFont();
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType('font', 'otf');
      request.response.headers
          .add('Cache-Control', 'public, max-age=31536000, immutable');
      request.response.add(bytes);
      await request.response.close();
    } catch (e) {
      Log.e('API', 'Failed to serve icon font: $e');
      request.response.statusCode = 500;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'error': 'font unavailable'}));
      await request.response.close();
    }
  }

  // --- Config web page ---

  Future<void> _serveConfigPage(HttpRequest request) async {
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.html;
    request.response.headers.add('X-Content-Type-Options', 'nosniff');
    request.response.headers.add('X-Frame-Options', 'DENY');

    // Determine selected panel from query string, default to the first
    // visible plugin. Conditionally-hidden plugins (isVisible false for the
    // current config, e.g. Capture when captureToolsEnabled is off) are
    // filtered out so they neither show in the sidebar nor render a panel.
    final config = _configNotifier.current;
    final panel = request.uri.queryParameters['panel'];
    final plugins =
        firstPartyPlugins.where((p) => p.isVisible(config)).toList();
    final selectedId =
        panel ?? (plugins.isNotEmpty ? plugins.first.id : '');

    final renderer = WebRenderer(
      plugins: plugins,
      bearerToken: _configNotifier.current.apiKey,
      config: _configNotifier.current,
    );
    request.response.write(renderer.render(selectedId: selectedId));
    await request.response.close();
  }

  // --- PIN entry page ---

  Future<void> _servePinPage(HttpRequest request) async {
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.html;
    request.response.write(_pinPageHtml);
    await request.response.close();
  }

  /// Cookie-or-bearer gate for endpoints reachable from a web portal
  /// `<a href>`. Returns true if authorized; otherwise writes 401 and
  /// returns false.
  bool _checkAuthOrSession(HttpRequest request) {
    if (_checkSession(request)) return true;
    final apiKey = _configNotifier.current.apiKey;
    final authHeader = request.headers.value('authorization');
    final token = authHeader != null && authHeader.startsWith('Bearer ')
        ? authHeader.substring(7)
        : null;
    if (token == apiKey) return true;

    request.response.statusCode = 401;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'error': 'unauthorized'}));
    request.response.close();
    return false;
  }

  Future<void> stop() async {
    await _server?.close();
  }
}

/// Loads the bundled MaterialIcons font from the Flutter asset bundle.
///
/// `uses-material-design: true` (pubspec) bundles the font, but there is no
/// fixed asset path to rely on — release/flutter-pi builds tree-shake the font
/// to a subset under a generated key. Discover the real key from
/// `FontManifest.json` rather than hardcoding, falling back to the canonical
/// path if the family isn't listed.
Future<List<int>> _loadBundledIconFont() async {
  String assetKey = 'fonts/MaterialIcons-Regular.otf';
  try {
    final manifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json'))
            as List<dynamic>;
    for (final family in manifest) {
      final m = family as Map<String, dynamic>;
      if (m['family'] == 'MaterialIcons') {
        final fonts = m['fonts'] as List<dynamic>;
        if (fonts.isNotEmpty) {
          final asset = (fonts.first as Map<String, dynamic>)['asset'];
          if (asset is String && asset.isNotEmpty) assetKey = asset;
        }
        break;
      }
    }
  } catch (_) {
    // Manifest missing/unreadable — fall back to the canonical asset key.
  }
  final data = await rootBundle.load(assetKey);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

final localApiServerProvider = Provider<LocalApiServer>((ref) {
  // Use ref.read — the server reads config/display state per-request,
  // so it doesn't need to be recreated when config changes.
  final displayService = ref.read(displayModeServiceProvider);
  final configNotifier = ref.read(hubConfigProvider.notifier);
  final timezoneService = ref.read(timezoneServiceProvider);
  final wifiService = ref.read(wifiServiceProvider);
  final updateService = ref.read(updateServiceProvider);
  final alarmService = ref.read(alarmServiceProvider);
  final notificationService = ref.read(notificationServiceProvider);
  final android = Platform.isAndroid;
  final server = LocalApiServer(
    displayModeService: displayService,
    configNotifier: configNotifier,
    timezoneService: timezoneService,
    wifiService: wifiService,
    updateService: updateService,
    alarmService: alarmService,
    notificationService: notificationService,
    screenNavigator: ref.read(screenNavigatorProvider),
    android: android,
    appUpdater: android ? ref.read(appUpdaterProvider.notifier) : null,
    // Generic tearoff: lets plugin routes reach any service provider
    // (HA, Immich, AlarmService, CaptureService, WifiService, ...) via
    // readProvider<T> — the Capture plugin reads captureServiceProvider this way.
    readProvider: ref.read,
  );
  ref.onDispose(() => server.stop());
  return server;
});

final webPinProvider = Provider<String>((ref) {
  return ref.read(localApiServerProvider).webPin;
});

const _logsPageHtml = r'''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Hearth Logs</title>
''' '$hearthFaviconLink' r'''
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    background: #111; color: #e0e0e0;
    display: flex; flex-direction: column; height: 100vh;
    padding: 16px;
  }
  .header {
    display: flex; justify-content: space-between; align-items: center;
    margin-bottom: 12px;
  }
  h1 { font-size: 20px; font-weight: 300; color: #fff; }
  .controls { display: flex; gap: 8px; align-items: center; }
  .controls a {
    color: #646cff; text-decoration: none; font-size: 13px;
  }
  .controls button {
    padding: 6px 14px; background: #333; color: #e0e0e0;
    border: 1px solid #444; border-radius: 6px; cursor: pointer; font-size: 13px;
  }
  .controls select {
    padding: 6px 8px; background: #1e1e1e; border: 1px solid #333;
    border-radius: 6px; color: #e0e0e0; font-size: 13px;
  }
  #logOutput {
    flex: 1; overflow-y: auto; padding: 12px;
    background: #0a0a0a; border: 1px solid #222; border-radius: 6px;
    font-family: "Cascadia Code", "Fira Code", monospace;
    font-size: 12px; line-height: 1.5; white-space: pre-wrap;
    word-break: break-all; color: #aaa;
  }
  .checkbox-label {
    display: flex; align-items: center; gap: 6px;
    font-size: 13px; color: #aaa; cursor: pointer;
  }
  .checkbox-label input { accent-color: #646cff; }
</style>
</head>
<body>
<div class="header">
  <h1>Hearth Logs</h1>
  <div class="controls">
    <a href="/">Settings</a>
    <select id="lineCount">
      <option value="50">50 lines</option>
      <option value="100" selected>100 lines</option>
      <option value="200">200 lines</option>
      <option value="500">500 lines</option>
    </select>
    <label class="checkbox-label">
      <input type="checkbox" id="autoRefresh" checked> Auto-refresh
    </label>
    <button onclick="fetchLogs()">Refresh</button>
  </div>
</div>
<div id="statsBar" style="display:flex;gap:16px;padding:8px 12px;margin-bottom:8px;background:#0a0a0a;border:1px solid #222;border-radius:6px;font-family:monospace;font-size:12px;color:#888;"></div>
<pre id="logOutput">Loading...</pre>
<script>
let API_KEY = '';
function getHeaders() {
  return {'Authorization': 'Bearer ' + API_KEY};
}
async function initAuth() {
  const r = await fetch('/api/session/key');
  if (r.ok) {
    const d = await r.json();
    API_KEY = d.apiKey;
  }
}
let refreshTimer = null;

async function fetchLogs() {
  const lines = document.getElementById('lineCount').value;
  try {
    const r = await fetch('/api/logs?lines=' + lines, {headers: getHeaders()});
    const d = await r.json();
    const el = document.getElementById('logOutput');
    el.textContent = d.logs || d.error || 'No logs';
    el.scrollTop = el.scrollHeight;
  } catch(e) {
    document.getElementById('logOutput').textContent = 'Failed to fetch logs';
  }
}

function toggleAutoRefresh() {
  if (refreshTimer) { clearInterval(refreshTimer); refreshTimer = null; }
  if (document.getElementById('autoRefresh').checked) {
    refreshTimer = setInterval(fetchLogs, 3000);
  }
}

document.getElementById('autoRefresh').addEventListener('change', toggleAutoRefresh);
document.getElementById('lineCount').addEventListener('change', fetchLogs);

async function fetchStats() {
  try {
    const r = await fetch('/api/system/stats', {headers: getHeaders()});
    const d = await r.json();
    const bar = document.getElementById('statsBar');
    bar.textContent = '';
    const upH = Math.floor(d.uptimeSeconds / 3600);
    const upM = Math.floor((d.uptimeSeconds % 3600) / 60);
    const memPct = d.memory.totalMb > 0 ? Math.round(d.memory.usedMb / d.memory.totalMb * 100) : 0;
    const items = [
      'CPU: ' + (d.cpu.tempC != null ? d.cpu.tempC.toFixed(1) + '\u00B0C' : '?'),
      'Load: ' + (d.cpu.load1m || '?'),
      'Mem: ' + d.memory.usedMb + '/' + d.memory.totalMb + ' MB (' + memPct + '%)',
      d.gpu.tempC != null ? 'GPU: ' + d.gpu.tempC.toFixed(1) + '\u00B0C' : null,
      'Up: ' + upH + 'h ' + upM + 'm',
    ];
    items.filter(Boolean).forEach(function(text) {
      const span = document.createElement('span');
      span.textContent = text;
      bar.appendChild(span);
    });
  } catch(e) {}
}

initAuth().then(() => { fetchLogs(); fetchStats(); toggleAutoRefresh(); setInterval(fetchStats, 3000); });
</script>
</body>
</html>
''';

// ---------------------------------------------------------------------------
// PIN entry page — shown when a web session is not yet authenticated.
// ---------------------------------------------------------------------------

const _pinPageHtml = r'''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Hearth — Unlock</title>
''' '$hearthFaviconLink' r'''
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    background: #111; color: #e0e0e0;
    display: flex; justify-content: center; align-items: center;
    min-height: 100vh; padding: 24px;
  }
  .card {
    text-align: center; width: 100%; max-width: 340px;
  }
  h1 { font-size: 28px; font-weight: 300; margin-bottom: 8px; color: #fff; }
  p { font-size: 14px; color: #888; margin-bottom: 24px; }
  input#pin {
    width: 160px; padding: 14px; text-align: center;
    font-size: 28px; letter-spacing: 12px;
    background: #1e1e1e; border: 1px solid #333; border-radius: 8px;
    color: #e0e0e0; outline: none;
  }
  input#pin:focus { border-color: #646cff; }
  button {
    display: block; width: 160px; margin: 16px auto 0;
    padding: 12px; background: #646cff; color: #fff;
    border: none; border-radius: 6px; font-size: 15px; cursor: pointer;
  }
  button:hover { background: #535bf2; }
  .error {
    margin-top: 12px; font-size: 13px; color: #f87171;
    min-height: 20px;
  }
</style>
</head>
<body>
<div class="card">
  <h1>Hearth</h1>
  <p>Enter the PIN shown on the kiosk display</p>
  <input type="text" id="pin" inputmode="numeric" maxlength="4" autofocus pattern="[0-9]*">
  <button onclick="unlock()">Unlock</button>
  <div class="error" id="error"></div>
</div>
<script>
document.getElementById('pin').addEventListener('keydown', function(e) {
  if (e.key === 'Enter') unlock();
});

async function unlock() {
  const pin = document.getElementById('pin').value;
  const err = document.getElementById('error');
  err.textContent = '';
  if (pin.length !== 4) { err.textContent = 'Enter a 4-digit PIN'; return; }
  try {
    const r = await fetch('/auth/pin', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({pin: pin})
    });
    if (r.ok) {
      window.location.reload();
    } else {
      err.textContent = 'Wrong PIN';
      document.getElementById('pin').value = '';
      document.getElementById('pin').focus();
    }
  } catch(e) {
    err.textContent = 'Connection error';
  }
}
</script>
</body>
</html>
''';
