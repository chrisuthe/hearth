import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../app/current_screen_provider.dart';
import '../app/screen_navigator.dart';
import '../config/hub_config.dart';
import '../models/music_state.dart';
import '../modules/alarm_clock/alarm_models.dart';
import '../modules/alarm_clock/alarm_service.dart';
import '../utils/alsa_utils.dart';
import '../utils/device_ip.dart';
import '../utils/logger.dart';
import 'installed_version.dart';
import 'music_assistant_service.dart';
import 'notification_service.dart';
import 'timer_service.dart';

/// Connection lifecycle of [MqttService], surfaced to the settings panel.
enum MqttStatus { disconnected, connecting, connected }

/// One Home Assistant MQTT discovery config message: the retained topic and
/// the JSON payload describing a single entity.
@immutable
class MqttDiscoveryEntry {
  final String topic;
  final Map<String, dynamic> config;
  const MqttDiscoveryEntry(this.topic, this.config);
}

/// Exposes Hearth to Home Assistant as a single MQTT device via the
/// [HA MQTT discovery](https://www.home-assistant.io/integrations/mqtt/#mqtt-discovery)
/// protocol.
///
/// Lifecycle mirrors [MusicAssistantService]: it watches the `mqtt*` config
/// fields, connects when a broker URL is set, disconnects when it is cleared,
/// and reconnects with exponential backoff on an unexpected drop. When no
/// broker is configured it is a complete no-op.
///
/// On connect it publishes retained discovery payloads (one shared Hearth
/// device-identity block across every entity), publishes current state for
/// each read entity, and subscribes to the command topics that drive Hearth
/// from HA (volume, timers, alarms, the screen select). State is republished whenever the
/// underlying service reports a change.
class MqttService extends ChangeNotifier {
  MqttService(
    this._ref, {
    String Function()? hostname,
    Random? random,
    bool? volumeSupported,
    Future<String> Function()? deviceModel,
    Future<String?> Function()? deviceIp,
    Future<String> Function()? installedVersion,
  })  : _hostname = hostname ?? _platformHostname,
        _random = random ?? Random.secure(),
        _volumeSupported = volumeSupported ?? (!kIsWeb && Platform.isLinux),
        _deviceModel = deviceModel ?? _platformDeviceModel,
        _deviceIp = deviceIp ?? lookupDeviceIp,
        _installedVersion = installedVersion ?? readInstalledVersion;

  final Ref _ref;
  final String Function() _hostname;
  final Random _random;
  // Volume is ALSA-only; elsewhere the entity would never get a state.
  final bool _volumeSupported;
  final Future<String> Function() _deviceModel;
  final Future<String?> Function() _deviceIp;
  final Future<String> Function() _installedVersion;

  MqttServerClient? _client;
  MqttStatus _status = MqttStatus.disconnected;
  MqttStatus get status => _status;
  bool get isConnected => _status == MqttStatus.connected;

  // Applied config snapshot — compared on updateConfig to decide whether to
  // reconnect, republish discovery, or do nothing.
  String _brokerUrl = '';
  String _username = '';
  String _password = '';
  String _discoveryPrefix = 'homeassistant';
  String _deviceNameSetting = '';
  String _versionFallback = '';

  // Resolved once per process; see [resolveDeviceId].
  String _clientId = '';
  String get deviceId => _clientId;
  // An id this install published under before it had a stored one, cleared
  // from the broker on the next connect.
  String? _legacyIdToClear;

  // Device identity sent with discovery, refreshed on each connect.
  String _swVersion = '';
  String _defaultDeviceName = 'Hearth';
  String? _configurationUrl;

  // Screen select options last sent with discovery; a layout change only
  // republishes discovery when these change.
  List<String> _screenOptions = const [];

  Timer? _reconnectTimer;
  int _reconnectDelay = 1;
  static const int _maxReconnectDelay = 30;
  bool _disposed = false;

  StreamSubscription<MusicPlayerState>? _playerSub;

  // Last-published change signatures, used to suppress republishing when the
  // source notifies (e.g. the 200ms timer ticker) without a meaningful change.
  String? _lastTimerSig;
  String? _lastAlarmSig;

  // Serializes inbound volume commands so concurrent amixer subprocesses can't
  // interleave and leave ALSA / the published state at the wrong value.
  Future<void> _volumeChain = Future.value();

  // --- Config-driven lifecycle ---------------------------------------------

  /// React to a config change: connect, disconnect, reconnect, or republish
  /// discovery as appropriate. Called with `fireImmediately` on creation.
  void updateConfig(HubConfig config) {
    if (kIsWeb) return; // The MQTT client is native-only.
    _versionFallback = config.currentVersion;
    if (_clientId.isEmpty && config.mqttDeviceId.isNotEmpty) {
      _clientId = config.mqttDeviceId;
    }
    final url = config.mqttBrokerUrl.trim();
    final user = config.mqttUsername;
    final pass = config.mqttPassword;
    final prefix = config.mqttDiscoveryPrefix.isEmpty
        ? 'homeassistant'
        : config.mqttDiscoveryPrefix;

    if (url.isEmpty) {
      // Integration turned off — tear down and stay quiet.
      _brokerUrl = '';
      if (_client != null || _status != MqttStatus.disconnected) {
        _disconnect();
      }
      return;
    }

    if (_clientId.isEmpty) _seedDeviceId();

    final connectionChanged =
        url != _brokerUrl || user != _username || pass != _password;
    final prefixChanged = prefix != _discoveryPrefix;
    final nameChanged = config.mqttDeviceName.trim() != _deviceNameSetting;

    _brokerUrl = url;
    _username = user;
    _password = pass;
    _discoveryPrefix = prefix;
    _deviceNameSetting = config.mqttDeviceName.trim();

    if (connectionChanged) {
      _reconnectDelay = 1;
      connect();
    } else if (prefixChanged && isConnected) {
      // Discovery topics are keyed by prefix — republish under the new one.
      _publishDiscovery();
      _publishAllState();
    } else if (nameChanged && isConnected) {
      _publishDiscovery();
    }
  }

  /// Resolve this install's device id and persist it, so it never changes.
  void _seedDeviceId() {
    final r = resolveDeviceId(hostname: _hostname, random: _random);
    _clientId = r.id;
    _legacyIdToClear = r.legacyId;
    Log.i('MQTT', 'Device id: ${r.id}');
    // Deferred: this can run while mqttServiceProvider is still building,
    // and a provider may not modify another during its initialization.
    Future.microtask(() => _ref
        .read(hubConfigProvider.notifier)
        .update((c) => c.copyWith(mqttDeviceId: r.id)));
  }

  /// (Re)subscribe to the Music Assistant player stream. Called whenever the
  /// MA service instance is (re)created so now-playing keeps flowing.
  void attachMusicAssistant(MusicAssistantService ma) {
    _playerSub?.cancel();
    _playerSub = ma.playerStateStream.listen((_) => onNowPlayingChanged());
  }

  /// Open a fresh broker connection. Overridden in tests to count attempts.
  @protected
  @visibleForTesting
  Future<void> connect() async {
    if (_disposed || kIsWeb || _brokerUrl.isEmpty) return;
    await _teardownClient();
    _reconnectTimer?.cancel();

    final broker = parseBroker(_brokerUrl);
    _setStatus(MqttStatus.connecting);

    final client =
        MqttServerClient.withPort(broker.host, _clientId, broker.port)
          ..secure = broker.secure
          ..keepAlivePeriod = 30
          ..autoReconnect = false
          ..setProtocolV311()
          ..logging(on: false)
          ..onDisconnected = _onDisconnected
          ..connectionMessage = MqttConnectMessage()
              .withClientIdentifier(_clientId)
              .startClean();
    if (broker.secure) {
      // LAN brokers commonly use self-signed certs.
      client.onBadCertificate = (Object cert) => true;
    }
    _client = client;

    try {
      await client.connect(
        _username.isEmpty ? null : _username,
        _password.isEmpty ? null : _password,
      );
    } catch (e) {
      Log.w('MQTT', 'Connect failed: $e');
      _abandonClient(client);
      // Only drive reconnect if a newer connect() hasn't superseded us.
      if (_client == client) {
        _client = null;
        _setStatus(MqttStatus.disconnected);
        _scheduleReconnect();
      }
      return;
    }

    // A concurrent connect() (e.g. another config change) took over while we
    // awaited — abandon this attempt and let the newer one own the lifecycle.
    if (_client != client) {
      _abandonClient(client);
      return;
    }

    if (client.connectionStatus?.state != MqttConnectionState.connected) {
      Log.w('MQTT', 'Connect incomplete: ${client.connectionStatus}');
      _abandonClient(client);
      _client = null;
      _setStatus(MqttStatus.disconnected);
      _scheduleReconnect();
      return;
    }

    _reconnectDelay = 1;
    _setStatus(MqttStatus.connected);
    Log.i('MQTT', 'Connected to ${broker.host}:${broker.port} as $_clientId');

    client.updates?.listen(_onMessage);
    await _refreshIdentity();
    if (_client != client) return;
    _clearLegacyId();
    _publishDiscovery();
    _subscribeCommands();
    await _publishAllState();
  }

  void _onDisconnected() {
    if (_disposed) return;
    Log.w('MQTT', 'Disconnected');
    _setStatus(MqttStatus.disconnected);
    if (_brokerUrl.isNotEmpty) _scheduleReconnect();
  }

  Future<void> _disconnect() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _teardownClient();
    _setStatus(MqttStatus.disconnected);
  }

  /// Drop the current client without scheduling a reconnect (its
  /// `onDisconnected` is detached first so the drop is silent).
  Future<void> _teardownClient() async {
    final c = _client;
    _client = null;
    if (c != null) _abandonClient(c);
  }

  /// Detach the disconnect handler and close a specific client. Used for the
  /// shared `_client` (via [_teardownClient]) and for abandoning a superseded
  /// connect attempt without touching `_client`.
  void _abandonClient(MqttServerClient client) {
    client.onDisconnected = null;
    try {
      client.disconnect();
    } catch (_) {}
  }

  void _scheduleReconnect() {
    if (_disposed || _brokerUrl.isEmpty) return;
    _reconnectTimer?.cancel();
    Log.w('MQTT', 'Reconnecting in ${_reconnectDelay}s...');
    _reconnectTimer = Timer(Duration(seconds: _reconnectDelay), () {
      _reconnectDelay = (_reconnectDelay * 2).clamp(1, _maxReconnectDelay);
      connect();
    });
  }

  void _setStatus(MqttStatus s) {
    if (_status == s) return;
    _status = s;
    notifyListeners();
  }

  // --- Topics ---------------------------------------------------------------

  String get _baseTopic => 'hearth/$_clientId';
  String _stateTopic(String entity) => '$_baseTopic/$entity/state';
  String _attrTopic(String entity) => '$_baseTopic/$entity/attributes';

  String get _volumeCmdTopic => '$_baseTopic/volume/set';
  String get _timerStartTopic => '$_baseTopic/timer/start';
  String get _timerCancelTopic => '$_baseTopic/timer/cancel';
  String get _alarmCreateTopic => '$_baseTopic/alarm/create';
  String get _alarmDeleteTopic => '$_baseTopic/alarm/delete';
  String get _alarmSnoozeTopic => '$_baseTopic/alarm/snooze';
  String get _alarmDismissTopic => '$_baseTopic/alarm/dismiss';
  String get _notifyTopic => '$_baseTopic/notify';
  String get _screenCmdTopic => '$_baseTopic/screen/set';

  /// Read the version, default name and portal URL sent with discovery.
  Future<void> _refreshIdentity() async {
    final version = await _installedVersion();
    _swVersion = version.isEmpty ? _versionFallback : version;
    final host = _realHostname(_hostname);
    _defaultDeviceName = defaultDeviceName(
      hostname: host,
      model: host == null ? await _deviceModel() : '',
    );
    final address = host ?? await _deviceIp();
    _configurationUrl = address == null ? null : 'http://$address:8090';
  }

  String get _deviceName =>
      _deviceNameSetting.isEmpty ? _defaultDeviceName : _deviceNameSetting;

  /// Remove the retained discovery and state left under the id this install
  /// used before it had a stored one, so HA drops that device.
  void _clearLegacyId() {
    final legacy = _legacyIdToClear;
    if (legacy == null) return;
    _legacyIdToClear = null;
    final entries = buildDiscoveryEntries(
      clientId: legacy,
      discoveryPrefix: _discoveryPrefix,
      swVersion: '',
      configurationUrl: null,
    );
    for (final e in entries) {
      _publish(e.topic, '');
      _publish(e.config['state_topic'] as String, '');
      final attrs = e.config['json_attributes_topic'] as String?;
      if (attrs != null) _publish(attrs, '');
    }
  }

  // --- Discovery ------------------------------------------------------------

  void _publishDiscovery() {
    _screenOptions = screenOptions(_ref.read(shellLayoutProvider).screens);
    final entries = buildDiscoveryEntries(
      clientId: _clientId,
      discoveryPrefix: _discoveryPrefix,
      swVersion: _swVersion,
      configurationUrl: _configurationUrl,
      deviceName: _deviceName,
      includeVolume: _volumeSupported,
      screenOptions: _screenOptions,
    );
    for (final e in entries) {
      _publish(e.topic, jsonEncode(e.config));
    }
    if (!_volumeSupported) {
      // An empty retained config removes a volume entity published earlier.
      _publish(volumeDiscoveryTopic(_discoveryPrefix, _clientId), '');
    }
  }

  // --- State publishing -----------------------------------------------------

  Future<void> _publishAllState() async {
    _lastTimerSig = null;
    _lastAlarmSig = null;
    onCurrentScreenChanged(_ref.read(currentScreenProvider));
    onNowPlayingChanged();
    onTimerChanged();
    onAlarmChanged();
    await publishVolume();
  }

  void onCurrentScreenChanged(CurrentScreen screen) {
    _publish(_stateTopic('current_screen'), screen.id);
    _publish(_attrTopic('current_screen'),
        jsonEncode({'screen_index': screen.index}));
    // The select reports the screen by name, matching its options.
    final screens = _ref.read(shellLayoutProvider).screens;
    final name = screens
        .firstWhere((s) => s.id == screen.id,
            orElse: () => ShellScreen(id: screen.id, name: screen.id))
        .name;
    _publish(_stateTopic('screen'), name);
  }

  /// The swipe row changed: republish the screen select's options when they
  /// differ, and its state, since the current screen's name may have changed.
  void onScreensChanged(ShellLayout layout) {
    if (!listEquals(screenOptions(layout.screens), _screenOptions)) {
      _publishDiscovery();
    }
    onCurrentScreenChanged(_ref.read(currentScreenProvider));
  }

  void onNowPlayingChanged() {
    final players = _ref.read(musicAssistantServiceProvider).playerStates;
    final np = _computeNowPlaying(players);
    _publish(_stateTopic('now_playing'), np.state);
    _publish(_attrTopic('now_playing'), jsonEncode(np.attrs));
  }

  ({String state, Map<String, dynamic> attrs}) _computeNowPlaying(
      Map<String, MusicPlayerState> players) {
    MusicPlayerState? chosen;
    for (final p in players.values) {
      if (p.isPlaying && p.currentTrack != null) {
        chosen = p;
        break;
      }
    }
    if (chosen == null) {
      for (final p in players.values) {
        if (p.currentTrack != null) {
          chosen = p;
          break;
        }
      }
    }
    final track = chosen?.currentTrack;
    if (track == null) {
      return (
        state: 'idle',
        attrs: {
          'artist': null,
          'album': null,
          'player_id': null,
          'playback_state': 'idle',
        },
      );
    }
    return (
      state: track.title,
      attrs: {
        'artist': track.artist,
        'album': track.album,
        'player_id': chosen!.activeZoneId,
        'playback_state': chosen.playbackState.name,
      },
    );
  }

  void onTimerChanged() {
    final ts = _ref.read(timerServiceProvider);
    final active = ts.timers;
    HubTimer? soonest;
    for (final t in active) {
      if (soonest == null || t.remaining < soonest.remaining) soonest = t;
    }
    final remaining = soonest?.remaining.inSeconds;
    // The 200ms ticker notifies far too often to forward raw. Bucket the
    // soonest remaining by 30s so a counting-down timer republishes at most
    // ~once per 30s — fresh enough for HA automations, without flooding.
    final sig = '${active.length}|${ts.hasActiveTimers}|${ts.firedTimers.length}'
        '|${remaining == null ? '' : remaining ~/ 30}';
    if (sig == _lastTimerSig) return;
    _lastTimerSig = sig;

    final state = ts.hasActiveTimers
        ? 'active'
        : (ts.firedTimers.isNotEmpty ? 'fired' : 'idle');
    _publish(_stateTopic('timer'), state);
    _publish(
      _attrTopic('timer'),
      jsonEncode({
        'count': active.length,
        'fired': ts.firedTimers.length,
        'remaining_seconds': remaining,
        'remaining': soonest?.remainingLabel,
      }),
    );
  }

  void onAlarmChanged() {
    final as = _ref.read(alarmServiceProvider);
    final na = as.nextAlarm;
    final sig =
        na == null ? 'none' : '${na.$1.id}|${na.$2.toIso8601String()}';
    if (sig == _lastAlarmSig) return;
    _lastAlarmSig = sig;

    if (na == null) {
      _publish(_stateTopic('next_alarm'), 'none');
      _publish(
        _attrTopic('next_alarm'),
        jsonEncode(
            {'label': null, 'days_summary': null, 'sunrise_enabled': false}),
      );
      return;
    }
    final (alarm, fireTime) = na;
    _publish(_stateTopic('next_alarm'), fireTime.toIso8601String());
    _publish(
      _attrTopic('next_alarm'),
      jsonEncode({
        'label': alarm.label,
        'days_summary': alarm.daySummary,
        'sunrise_enabled': alarm.sunriseDuration > 0,
      }),
    );
  }

  /// Read the live ALSA Master volume and publish it as the number state.
  Future<void> publishVolume() async {
    final v = await getMasterVolume();
    if (v == null) return;
    _publish(_stateTopic('volume'), v.toString());
  }

  void _publish(String topic, String payload, {bool retain = true}) {
    final c = _client;
    if (c == null ||
        c.connectionStatus?.state != MqttConnectionState.connected) {
      return;
    }
    final builder = MqttClientPayloadBuilder()..addString(payload);
    c.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!,
        retain: retain);
  }

  // --- Inbound commands -----------------------------------------------------

  void _subscribeCommands() {
    final c = _client;
    if (c == null) return;
    for (final topic in [
      if (_volumeSupported) _volumeCmdTopic,
      _timerStartTopic,
      _timerCancelTopic,
      _alarmCreateTopic,
      _alarmDeleteTopic,
      _alarmSnoozeTopic,
      _alarmDismissTopic,
      _notifyTopic,
      _screenCmdTopic,
    ]) {
      c.subscribe(topic, MqttQos.atLeastOnce);
    }
  }

  void _onMessage(List<MqttReceivedMessage<MqttMessage?>> events) {
    for (final event in events) {
      final pub = event.payload;
      if (pub is! MqttPublishMessage) continue;
      final payload =
          MqttPublishPayload.bytesToStringAsString(pub.payload.message);
      handleCommand(event.topic, payload);
    }
  }

  /// Dispatch one inbound command to the relevant Hearth service. Split out
  /// (and `@visibleForTesting`) so command handling can be exercised against
  /// real TimerService/AlarmService instances without a live broker.
  @visibleForTesting
  Future<void> handleCommand(String topic, String payload) async {
    try {
      if (topic == _volumeCmdTopic) {
        await _handleVolumeCommand(payload);
      } else if (topic == _timerStartTopic) {
        _handleTimerStart(payload);
      } else if (topic == _timerCancelTopic) {
        _handleTimerCancel(payload);
      } else if (topic == _alarmCreateTopic) {
        _handleAlarmCreate(payload);
      } else if (topic == _alarmDeleteTopic) {
        _handleAlarmDelete(payload);
      } else if (topic == _alarmSnoozeTopic) {
        _ref.read(alarmServiceProvider).snooze();
      } else if (topic == _alarmDismissTopic) {
        _ref.read(alarmServiceProvider).dismiss();
      } else if (topic == _notifyTopic) {
        _handleNotify(payload);
      } else if (topic == _screenCmdTopic) {
        if (_ref.read(screenNavigatorProvider).show(payload) == null) {
          Log.w('MQTT', 'Unknown screen: $payload');
        }
      } else {
        Log.w('MQTT', 'Unhandled command topic: $topic');
      }
    } catch (e) {
      Log.w('MQTT', 'Command handling failed ($topic): $e');
    }
  }

  Future<void> _handleVolumeCommand(String payload) {
    final v = int.tryParse(payload.trim());
    if (v == null) {
      Log.w('MQTT', 'Bad volume payload: $payload');
      return Future.value();
    }
    // Chain onto any in-flight volume write so they apply in arrival order;
    // the catchError keeps the chain alive if a write ever throws.
    _volumeChain = _volumeChain.then((_) async {
      await setMasterVolume(v);
      await publishVolume();
    }).catchError((Object e) {
      Log.w('MQTT', 'Volume command failed: $e');
    });
    return _volumeChain;
  }

  void _handleTimerStart(String payload) {
    final data = _decodeJson(payload);
    final seconds = (data['duration'] as num?)?.round();
    if (seconds == null || seconds <= 0) {
      Log.w('MQTT', 'Bad timer duration: $payload');
      return;
    }
    _ref.read(timerServiceProvider).startTimer(Duration(seconds: seconds));
  }

  void _handleTimerCancel(String payload) {
    final ts = _ref.read(timerServiceProvider);
    final data = _decodeJson(payload);
    final id = (data['timer_id'] as num?)?.toInt();
    if (id != null) {
      final exists = ts.timers.any((t) => t.id == id) ||
          ts.firedTimers.any((t) => t.id == id);
      if (exists) ts.dismissTimer(id);
      return;
    }
    // No id — dismiss the most-recently-started active timer, else clear fired.
    // Voice timers are Home Assistant's to cancel, not ours.
    final active = ts.timers.where((t) => !t.isRemote).toList()
      ..sort((a, b) => b.id.compareTo(a.id));
    if (active.isNotEmpty) {
      ts.dismissTimer(active.first.id);
    } else if (ts.firedTimers.isNotEmpty) {
      ts.dismissAllFired();
    }
  }

  void _handleAlarmCreate(String payload) {
    final data = _decodeJson(payload);
    final time = data['time'] as String?;
    if (time == null || time.isEmpty) {
      Log.w('MQTT', 'Alarm create missing time: $payload');
      return;
    }
    final days = (data['days'] as List?)
            ?.map((e) => (e as num).toInt())
            .toList() ??
        const <int>[];
    // Reuse Alarm.fromJson so the id is generated and defaults are applied.
    final alarm = Alarm.fromJson({
      'time': time,
      'label': data['label'],
      'days': days,
      if (data['sunrise_duration'] != null)
        'sunriseDuration': (data['sunrise_duration'] as num).toInt(),
    });
    _ref.read(alarmServiceProvider).addAlarm(alarm);
  }

  /// Normalize an inbound notification payload and surface it as a deck card.
  /// HA publishes JSON to `hearth/<clientId>/notify`. Shares the normalize path
  /// (`NotificationService.ingestPayload`) with `POST /api/notify`.
  ///
  /// Payload schema (all optional except one of title/message):
  /// ```json
  /// {"title": "...", "message": "...", "priority": "alert"|"info",
  ///  "sticky": true|false, "source": "...", "source_label": "...",
  ///  "muted": true|false, "image": "/api/camera_proxy/camera.x",
  ///  "image_refresh": 3, "camera": "front_door", "tag": "front_door",
  ///  "timeout": 180}
  /// ```
  /// `{"tag": "...", "clear": true}` closes that card.
  ///
  /// Two HA delivery paths (both land here):
  ///
  /// 1. `notify.mqtt` (HA 2024.5+) — the built-in MQTT notify entity. Its
  ///    `command_template` only has the message text (rendered as `value`);
  ///    title/priority/sticky are NOT template variables, so this path gives a
  ///    simple message-only card (title falls back to the message):
  /// ```yaml
  /// mqtt:
  ///   - notify:
  ///       name: Hearth
  ///       command_topic: "hearth/<clientId>/notify"
  ///       command_template: '{"message": {{ value | to_json }}}'
  /// ```
  ///
  /// 2. `mqtt.publish` — publish the full JSON yourself for title/priority/
  ///    sticky control (e.g. from an automation):
  /// ```yaml
  /// action: mqtt.publish
  /// data:
  ///   topic: "hearth/<clientId>/notify"
  ///   payload: >-
  ///     {"title": "Laundry", "message": "Cycle finished",
  ///      "priority": "info", "sticky": false}
  /// ```
  void _handleNotify(String payload) {
    final id =
        _ref.read(notificationServiceProvider).ingestPayload(_decodeJson(payload));
    if (id == null) {
      Log.w('MQTT', 'Invalid notify payload: $payload');
    }
  }

  void _handleAlarmDelete(String payload) {
    final data = _decodeJson(payload);
    final id = data['alarm_id'] as String?;
    if (id == null || id.isEmpty) {
      Log.w('MQTT', 'Alarm delete missing alarm_id: $payload');
      return;
    }
    _ref.read(alarmServiceProvider).deleteAlarm(id);
  }

  Map<String, dynamic> _decodeJson(String payload) {
    if (payload.trim().isEmpty) return const {};
    try {
      final v = jsonDecode(payload);
      return v is Map<String, dynamic> ? v : const {};
    } catch (_) {
      return const {};
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _playerSub?.cancel();
    _teardownClient();
    super.dispose();
  }

  // --- Pure, testable helpers ----------------------------------------------

  /// Build the HA discovery config entries for every entity this integration
  /// exposes. All entries share one device-identity block so HA groups them
  /// under a single "Hearth" device.
  @visibleForTesting
  static List<MqttDiscoveryEntry> buildDiscoveryEntries({
    required String clientId,
    required String discoveryPrefix,
    required String swVersion,
    required String? configurationUrl,
    String deviceName = 'Hearth',
    bool includeVolume = true,
    List<String> screenOptions = const ['Home', 'Settings'],
  }) {
    final base = 'hearth/$clientId';
    final device = <String, dynamic>{
      'identifiers': ['hearth_$clientId'],
      'name': deviceName,
      'model': 'Hearth Kiosk',
      'manufacturer': 'Hearth',
      'sw_version': swVersion.isEmpty ? 'unknown' : swVersion,
      'configuration_url': ?configurationUrl,
    };

    String topic(String component, String entity) =>
        '$discoveryPrefix/$component/hearth_$clientId/$entity/config';
    String uid(String entity) => 'hearth_${clientId}_$entity';

    MqttDiscoveryEntry sensor(
      String entity,
      String name,
      String icon,
    ) =>
        MqttDiscoveryEntry(topic('sensor', entity), {
          'name': name,
          'unique_id': uid(entity),
          'state_topic': '$base/$entity/state',
          'json_attributes_topic': '$base/$entity/attributes',
          'icon': icon,
          'device': device,
        });

    return [
      sensor('current_screen', 'Current Screen', 'mdi:monitor-dashboard'),
      sensor('now_playing', 'Now Playing', 'mdi:music'),
      sensor('timer', 'Timer', 'mdi:timer-outline'),
      sensor('next_alarm', 'Next Alarm', 'mdi:alarm'),
      MqttDiscoveryEntry(topic('select', 'screen'), {
        'name': 'Screen',
        'unique_id': uid('screen'),
        'state_topic': '$base/screen/state',
        'command_topic': '$base/screen/set',
        'options': screenOptions,
        'icon': 'mdi:view-carousel',
        'device': device,
      }),
      if (includeVolume)
        MqttDiscoveryEntry(volumeDiscoveryTopic(discoveryPrefix, clientId), {
          'name': 'Volume',
          'unique_id': uid('volume'),
          'state_topic': '$base/volume/state',
          'command_topic': '$base/volume/set',
          'min': 0,
          'max': 100,
          'step': 1,
          'mode': 'slider',
          'unit_of_measurement': '%',
          'icon': 'mdi:volume-high',
          'device': device,
        }),
    ];
  }

  /// The screen select's options: each screen's name, once. A name two
  /// screens share is offered once and selects the first; the other is still
  /// reachable by id on the command topic.
  @visibleForTesting
  static List<String> screenOptions(List<ShellScreen> screens) =>
      {for (final s in screens) s.name}.toList();

  @visibleForTesting
  static String volumeDiscoveryTopic(String discoveryPrefix, String clientId) =>
      '$discoveryPrefix/number/hearth_$clientId/volume/config';

  /// Parse a broker URL into host/port/secure. Accepts bare `host`,
  /// `host:port`, and scheme-prefixed forms (`mqtt://`, `mqtts://`,
  /// `tcp://`, `ssl://`). Defaults to port 1883 (8883 when secure).
  @visibleForTesting
  static ({String host, int port, bool secure}) parseBroker(String url) {
    var u = url.trim();
    var secure = false;
    final scheme = RegExp(r'^([a-zA-Z]+)://').firstMatch(u);
    if (scheme != null) {
      final s = scheme.group(1)!.toLowerCase();
      secure = s == 'mqtts' || s == 'ssl' || s == 'tls' || s == 'wss';
      u = u.substring(scheme.end);
    }
    u = u.split('/').first; // strip any trailing path
    var host = u;
    var port = secure ? 8883 : 1883;
    final colon = u.lastIndexOf(':');
    if (colon > 0) {
      final maybePort = int.tryParse(u.substring(colon + 1));
      if (maybePort != null) {
        host = u.substring(0, colon);
        port = maybePort;
      }
    }
    if (host.isEmpty) host = 'localhost';
    return (host: host, port: port, secure: secure);
  }

  /// The id this install publishes under: the MQTT client id, the topic
  /// base, the HA device identifier and every `unique_id`.
  ///
  /// A real hostname keeps the sanitized hostname, the id every install used
  /// before ids were stored, so an existing HA device survives. Android
  /// reports `localhost`, which every tablet shares, so it and a failed lookup
  /// get a generated `hearth_<hex>`; [legacyId] is then `localhost` when that
  /// is what the install published under before.
  @visibleForTesting
  static ({String id, String? legacyId}) resolveDeviceId({
    required String Function() hostname,
    required Random random,
  }) {
    String? sanitized;
    try {
      sanitized = _sanitizeId(hostname());
    } catch (_) {}
    if (sanitized != null &&
        sanitized.isNotEmpty &&
        sanitized != 'localhost' &&
        sanitized.replaceAll('_', '').isNotEmpty) {
      return (id: sanitized, legacyId: null);
    }
    final hex = List.generate(
      8,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
    return (
      id: 'hearth_$hex',
      legacyId: sanitized == 'localhost' ? 'localhost' : null,
    );
  }

  /// The HA device name when none is set: the hostname, or on Android (no
  /// hostname) the device model, so two kiosks never share a name.
  @visibleForTesting
  static String defaultDeviceName({String? hostname, String model = ''}) {
    if (hostname != null) {
      return hostname.toLowerCase() == 'hearth'
          ? 'Hearth'
          : 'Hearth ($hostname)';
    }
    final m = model.trim();
    return m.isEmpty ? 'Hearth' : 'Hearth ($m)';
  }

  static String _sanitizeId(String raw) =>
      raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_');

  /// The hostname, or null when the lookup fails or gives `localhost`.
  static String? _realHostname(String Function() hostname) {
    try {
      final h = hostname().trim();
      if (h.isEmpty || h.toLowerCase() == 'localhost') return null;
      return h;
    } catch (_) {
      return null;
    }
  }

  static String _platformHostname() => Platform.localHostname;

  static Future<String> _platformDeviceModel() async {
    if (kIsWeb || !Platform.isAndroid) return '';
    try {
      final r = await Process.run('getprop', ['ro.product.model']);
      return (r.stdout as String).trim();
    } catch (_) {
      return '';
    }
  }
}

/// MqttService is created once and pushed config/state changes; it is never
/// recreated by Riverpod (nothing is `watch`ed here), so the live connection
/// survives unrelated config edits.
final mqttServiceProvider = ChangeNotifierProvider<MqttService>((ref) {
  // ChangeNotifierProvider disposes the notifier automatically (which cancels
  // the reconnect timer, MA subscription, and client) — no explicit onDispose.
  final service = MqttService(ref);

  // Connect/disconnect/reconnect on config changes.
  ref.listen<HubConfig>(
    hubConfigProvider,
    (_, next) => service.updateConfig(next),
    fireImmediately: true,
  );

  // Current-screen sensor: publish on page change.
  ref.listen<CurrentScreen>(
    currentScreenProvider,
    (_, next) => service.onCurrentScreenChanged(next),
  );

  // Screen select: its options follow the swipe row.
  ref.listen<ShellLayout>(
    shellLayoutProvider,
    (_, next) => service.onScreensChanged(next),
  );

  // Timer + alarm sensors: read the stable notifier and listen directly
  // (watching a ChangeNotifierProvider here would recreate the service on
  // every notify).
  final timer = ref.read(timerServiceProvider);
  timer.addListener(service.onTimerChanged);
  ref.onDispose(() => timer.removeListener(service.onTimerChanged));

  final alarm = ref.read(alarmServiceProvider);
  alarm.addListener(service.onAlarmChanged);
  ref.onDispose(() => alarm.removeListener(service.onAlarmChanged));

  // Now-playing sensor: re-attach the MA stream whenever the MA service is
  // (re)created so it keeps flowing across MA reconnects.
  ref.listen<MusicAssistantService>(
    musicAssistantServiceProvider,
    (_, next) => service.attachMusicAssistant(next),
    fireImmediately: true,
  );

  return service;
});
