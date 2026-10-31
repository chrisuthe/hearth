import 'dart:math';

class Alarm {
  final String id;
  final String time; // "HH:mm" 24h format
  final String label;
  final bool enabled;
  final List<int> days; // ISO weekdays: 1=Mon, 7=Sun. Empty = one-time.
  final bool oneTime;
  final int sunriseDuration; // minutes, 0 = off
  final List<String> sunriseLights; // HA entity IDs
  final String soundType; // "builtin", "music_assistant", "none"
  final String soundId;
  final int snoozeDuration; // minutes
  final double volume; // 0.0-1.0

  const Alarm({
    required this.id,
    required this.time,
    this.label = '',
    this.enabled = true,
    this.days = const [],
    this.oneTime = false,
    this.sunriseDuration = 0,
    this.sunriseLights = const [],
    this.soundType = 'builtin',
    this.soundId = 'gentle_morning',
    this.snoozeDuration = 10,
    this.volume = 0.7,
  });

  int get hour => int.parse(time.split(':')[0]);
  int get minute => int.parse(time.split(':')[1]);

  Alarm copyWith({
    String? id,
    String? time,
    String? label,
    bool? enabled,
    List<int>? days,
    bool? oneTime,
    int? sunriseDuration,
    List<String>? sunriseLights,
    String? soundType,
    String? soundId,
    int? snoozeDuration,
    double? volume,
  }) {
    return Alarm(
      id: id ?? this.id,
      time: time ?? this.time,
      label: label ?? this.label,
      enabled: enabled ?? this.enabled,
      days: days ?? this.days,
      oneTime: oneTime ?? this.oneTime,
      sunriseDuration: sunriseDuration ?? this.sunriseDuration,
      sunriseLights: sunriseLights ?? this.sunriseLights,
      soundType: soundType ?? this.soundType,
      soundId: soundId ?? this.soundId,
      snoozeDuration: snoozeDuration ?? this.snoozeDuration,
      volume: volume ?? this.volume,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'time': time,
        'label': label,
        'enabled': enabled,
        'days': days,
        'oneTime': oneTime,
        'sunriseDuration': sunriseDuration,
        'sunriseLights': sunriseLights,
        'soundType': soundType,
        'soundId': soundId,
        'snoozeDuration': snoozeDuration,
        'volume': volume,
      };

  factory Alarm.fromJson(Map<String, dynamic> json) => Alarm(
        id: json['id'] as String? ?? _generateId(),
        time: json['time'] as String? ?? '07:00',
        label: json['label'] as String? ?? '',
        enabled: json['enabled'] as bool? ?? true,
        days: (json['days'] as List<dynamic>?)?.cast<int>() ?? const [],
        oneTime: json['oneTime'] as bool? ?? false,
        sunriseDuration: json['sunriseDuration'] as int? ?? 0,
        sunriseLights:
            (json['sunriseLights'] as List<dynamic>?)?.cast<String>() ??
                const [],
        soundType: json['soundType'] as String? ?? 'builtin',
        soundId: json['soundId'] as String? ?? 'gentle_morning',
        snoozeDuration: json['snoozeDuration'] as int? ?? 10,
        volume: (json['volume'] as num?)?.toDouble() ?? 0.7,
      );

  /// Compute the next DateTime this alarm will fire.
  DateTime? nextFireTime(DateTime now) {
    if (!enabled) return null;
    final todayFire = DateTime(now.year, now.month, now.day, hour, minute);

    if (days.isEmpty) {
      // One-time: next occurrence of this time.
      return todayFire.isAfter(now)
          ? todayFire
          : todayFire.add(const Duration(days: 1));
    }

    // Recurring: find next matching day.
    for (int offset = 0; offset < 8; offset++) {
      final candidate = todayFire.add(Duration(days: offset));
      if (days.contains(candidate.weekday)) {
        if (candidate.isAfter(now)) return candidate;
      }
    }
    return null;
  }

  /// Human-readable day summary.
  String get daySummary {
    if (days.isEmpty) return oneTime ? 'One time' : 'Tomorrow';
    if (days.length == 7) return 'Every day';
    if (const [1, 2, 3, 4, 5].every(days.contains) && days.length == 5) {
      return 'Weekdays';
    }
    if (const [6, 7].every(days.contains) && days.length == 2) {
      return 'Weekends';
    }
    const names = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return days.map((d) => names[d]).join(', ');
  }

  static String _generateId() {
    final r = Random.secure();
    return List.generate(6, (_) => r.nextInt(36).toRadixString(36)).join();
  }
}
