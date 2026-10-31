/// Represents a single Home Assistant entity's state.
///
/// HA entities follow the pattern `domain.object_id` (e.g., `light.kitchen`).
/// The [attributes] map varies by domain — lights have brightness/color,
/// climate entities have temperature/hvac_mode, etc. This model provides
/// typed accessors for the domains we care about while keeping the raw
/// attributes available for anything we haven't explicitly modeled.
class HaEntity {
  final String entityId;
  final String state;
  final Map<String, dynamic> attributes;
  final DateTime lastChanged;

  const HaEntity({
    required this.entityId,
    required this.state,
    this.attributes = const {},
    required this.lastChanged,
  });

  /// The domain portion of the entity ID (e.g., "light", "climate", "sensor").
  String get domain => entityId.split('.').first;

  /// Human-readable name from HA's friendly_name attribute,
  /// falling back to the object_id portion of the entity ID.
  String get name =>
      attributes['friendly_name'] as String? ?? entityId.split('.').last;

  // --- Light-specific accessors ---
  // HA reports brightness as 0-255 int; UI layer converts to percentage.
  int? get brightness => attributes['brightness'] as int?;

  /// Whether a light can be set below full. `onoff` is the one colour mode
  /// without brightness: Home Assistant drops the brightness and turns it on.
  bool get isDimmable {
    final modes = attributes['supported_color_modes'];
    return modes is List && modes.any((m) => m != 'onoff' && m != 'unknown');
  }

  // Color temperature in mireds (HA's native unit for color temp).
  double? get colorTemp => (attributes['color_temp'] as num?)?.toDouble();

  // RGB color as a three-element list [r, g, b], each 0-255.
  List<int>? get rgbColor {
    final rgb = attributes['rgb_color'];
    if (rgb is List) return rgb.cast<int>();
    return null;
  }

  // --- Climate-specific accessors ---
  // Target temperature set by the user.
  double? get temperature => (attributes['temperature'] as num?)?.toDouble();

  // Current reading from the thermostat's sensor.
  double? get currentTemperature =>
      (attributes['current_temperature'] as num?)?.toDouble();

  // HVAC operating mode: "heat", "cool", "heat_cool", "auto", "off", etc.
  String? get hvacMode => attributes['hvac_mode'] as String?;

  // --- State convenience checks ---
  bool get isOn => state == 'on';
  bool get isOff => state == 'off';
  bool get isUnavailable => state == 'unavailable';

  /// Parses from the `new_state` object inside a HA WebSocket `state_changed`
  /// event. The WebSocket API docs describe the event data shape:
  /// https://developers.home-assistant.io/docs/api/websocket/#subscribe-to-events
  factory HaEntity.fromEventData(Map<String, dynamic> data) {
    return HaEntity(
      entityId: data['entity_id'] as String,
      state: data['state'] as String,
      attributes:
          (data['attributes'] as Map<String, dynamic>?) ?? const {},
      lastChanged: DateTime.parse(data['last_changed'] as String),
    );
  }

  /// Serializes back to the same JSON shape used by HA, which is useful for
  /// caching entity state locally between WebSocket reconnections.
  Map<String, dynamic> toJson() => {
        'entity_id': entityId,
        'state': state,
        'attributes': attributes,
        'last_changed': lastChanged.toIso8601String(),
      };
}
