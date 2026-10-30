import 'package:flutter/foundation.dart';

/// Where a [HearthNotification] originated. Drives the source chip label and,
/// for [timer], tells [NotificationService] to leave chime playback to
/// `TimerService` (which owns the looping fired-timer beep).
enum NotificationSource { frigate, unifi, ha, push, timer }

/// Severity of a notification. Determines the accent colour/ring, the derived
/// chime, and the default stickiness when a payload omits it.
enum NotificationPriority { alert, info }

/// Uppercase mono chip text shown for each source, matching the design handoff
/// ("FRIGATE" / "PROTECT" / "HOME ASST" / "PUSH" / "TIMER").
String defaultSourceLabel(NotificationSource source) {
  switch (source) {
    case NotificationSource.frigate:
      return 'FRIGATE';
    case NotificationSource.unifi:
      return 'PROTECT';
    case NotificationSource.ha:
      return 'HOME ASST';
    case NotificationSource.push:
      return 'PUSH';
    case NotificationSource.timer:
      return 'TIMER';
  }
}

NotificationPriority _priorityFromString(Object? value) {
  final s = (value as String?)?.trim().toLowerCase();
  return s == 'alert' ? NotificationPriority.alert : NotificationPriority.info;
}

NotificationSource? _sourceFromString(Object? value) {
  final s = (value as String?)?.trim().toLowerCase();
  if (s == null || s.isEmpty) return null;
  for (final source in NotificationSource.values) {
    if (source.name == s) return source;
  }
  // Accept a couple of friendly aliases HA users might send.
  if (s == 'unifi' || s == 'protect') return NotificationSource.unifi;
  if (s == 'home_assistant' || s == 'homeassistant') return NotificationSource.ha;
  return null;
}

/// A non-blank string, or null for anything else. The optional picture and tag
/// fields tolerate a bad value rather than rejecting the whole notification.
String? _optionalString(Object? value) {
  if (value is! String) return null;
  final s = value.trim();
  return s.isEmpty ? null : s;
}

/// A positive number of seconds (a number or numeric string), or null.
Duration? _optionalSeconds(Object? value) {
  final seconds = value is num
      ? value
      : value is String
          ? num.tryParse(value.trim())
          : null;
  if (seconds == null || seconds <= 0) return null;
  return Duration(milliseconds: (seconds * 1000).round());
}

/// How long a card with a refreshing picture lives without a `timeout`, so a
/// lost close message can't leave it polling forever.
const Duration kDefaultRefreshingCardTimeout = Duration(minutes: 10);

/// A single notification, normalized across every source (Frigate, Unifi, HA,
/// generic push, and fired timers) into one shape.
@immutable
class HearthNotification {
  final String id;
  final NotificationSource source;

  /// Uppercase chip text (e.g. "HOME ASST"). Defaults to [defaultSourceLabel]
  /// for [source] when a payload doesn't override it.
  final String sourceLabel;
  final NotificationPriority priority;
  final String title;
  final String body;

  /// Sticky cards stay until dismissed; transient cards auto-dismiss after 6s.
  final bool sticky;

  /// Whether the card arrives muted (no chime, "Muted" label). Rarely set by a
  /// payload; the per-card mute toggle is otherwise a runtime UI state.
  final bool muted;

  final DateTime timestamp;

  /// Invoked by [NotificationService] when this card is removed by any path
  /// (dismiss, swipe, clearAll). Used to wire a fired-timer card back to
  /// `TimerService.dismissTimer` so dismissing the card stops the timer.
  final VoidCallback? onDismiss;

  /// Picture for the card: an HA-relative path or an http(s) URL. See
  /// `NotificationImageLoader` for how it resolves.
  final String? image;

  /// Re-fetch [image] at this interval. Null means fetch once.
  final Duration? imageRefresh;

  /// Frigate camera name. Makes the card tappable, opening that camera's feed.
  final String? camera;

  /// Stable identity: ingesting the same tag again updates the existing card.
  final String? tag;

  /// Close the card this long after its last update.
  final Duration? timeout;

  const HearthNotification({
    required this.id,
    required this.source,
    required this.sourceLabel,
    required this.priority,
    required this.title,
    required this.body,
    required this.sticky,
    required this.timestamp,
    this.muted = false,
    this.onDismiss,
    this.image,
    this.imageRefresh,
    this.camera,
    this.tag,
    this.timeout,
  });

  /// The card id for a [tag]. A stable id is what makes an update land on the
  /// existing card.
  static String idForTag(String tag) => 'tag-$tag';

  /// The valid `tag` in an ingest payload, if any.
  static String? tagFromPayload(Map<String, dynamic> json) =>
      _optionalString(json['tag']);

  /// The chime name shown next to the equalizer, derived from [priority].
  String get chimeLabel =>
      priority == NotificationPriority.alert ? 'Ember Alert' : 'Soft Ping';

  /// This notification with [timestamp] and [onDismiss] taken from [previous],
  /// the card it is updating.
  HearthNotification updating(HearthNotification previous) =>
      HearthNotification(
        id: id,
        source: source,
        sourceLabel: sourceLabel,
        priority: priority,
        title: title,
        body: body,
        sticky: sticky,
        timestamp: previous.timestamp,
        muted: muted,
        onDismiss: onDismiss ?? previous.onDismiss,
        image: image,
        imageRefresh: imageRefresh,
        camera: camera,
        tag: tag,
        timeout: timeout,
      );

  /// Normalize an inbound ingest payload (shared by the MQTT `.../notify`
  /// topic and `POST /api/notify`) into a notification.
  ///
  /// Recognized keys: `title`, `message` (aka `body`), `priority`
  /// (`alert`|`info`, default `info`), `sticky` (default: sticky for alerts,
  /// transient for info), `source` (default [fallbackSource]), `source_label`,
  /// `muted`, `image`, `image_refresh`, `camera`, `tag` and `timeout`. A
  /// `timeout` takes precedence over `sticky`, and a refreshing picture with no
  /// `timeout` gets [kDefaultRefreshingCardTimeout]. Returns null when neither
  /// a title nor a body is present so the caller can reject an empty
  /// notification.
  static HearthNotification? fromIngest(
    Map<String, dynamic> json, {
    NotificationSource fallbackSource = NotificationSource.ha,
    DateTime? now,
  }) {
    final title = (json['title'] as String?)?.trim() ?? '';
    final body =
        ((json['message'] ?? json['body']) as String?)?.trim() ?? '';
    if (title.isEmpty && body.isEmpty) return null;

    final priority = _priorityFromString(json['priority']);
    final source = _sourceFromString(json['source']) ?? fallbackSource;
    final label = (json['source_label'] as String?)?.trim();
    final ts = now ?? DateTime.now();
    final tag = tagFromPayload(json);
    final requestedRefresh = _optionalSeconds(json['image_refresh']);
    final imageRefresh = requestedRefresh == null ||
            requestedRefresh >= const Duration(seconds: 1)
        ? requestedRefresh
        : const Duration(seconds: 1);
    final timeout = _optionalSeconds(json['timeout']) ??
        (imageRefresh != null ? kDefaultRefreshingCardTimeout : null);

    return HearthNotification(
      id: tag != null ? idForTag(tag) : 'ext-${ts.microsecondsSinceEpoch}',
      source: source,
      sourceLabel: (label != null && label.isNotEmpty)
          ? label
          : defaultSourceLabel(source),
      priority: priority,
      title: title.isEmpty ? body : title,
      body: title.isEmpty ? '' : body,
      sticky: timeout != null ||
          (json['sticky'] as bool? ?? priority == NotificationPriority.alert),
      muted: json['muted'] as bool? ?? false,
      timestamp: ts,
      image: _optionalString(json['image']),
      imageRefresh: imageRefresh,
      camera: _optionalString(json['camera']),
      tag: tag,
      timeout: timeout,
    );
  }
}
