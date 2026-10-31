// Design tokens for the notification bottom-deck surface.
//
// Mapped from the "Hearth — Notifications & Alerts" handoff (Direction 1B,
// "Hearthstones"). The handoff is authored portrait 1200x1920; Hearth renders
// landscape 1184x864, so spacing/type come from the shared Hearth tokens
// (already calibrated for this canvas) — only the warm palette, radii, and
// motion curve are lifted verbatim here.
//
// Grouped as classes of `static const` members (matching `media_tokens.dart`)
// so they tree-shake and read like enums at call sites.

import 'package:flutter/animation.dart';

class NotifColors {
  NotifColors._();

  /// Warm white — titles and primary text (#F3ECE1).
  static const Color text = Color(0xFFF3ECE1);

  /// Muted warm grey — labels, body, chime name (#A79D8E).
  static const Color textMuted = Color(0xFFA79D8E);

  /// Dimmer warm grey — timestamps, tag pills (#8F8676).
  static const Color textDim = Color(0xFF8F8676);

  /// Glass fill for the card, over a 24px backdrop blur (rgba(26,21,17,0.66)).
  static const Color cardGlass = Color.fromRGBO(26, 21, 17, 0.66);

  /// Hairline / info-priority ring (rgba(255,255,255,0.10)).
  static const Color hairline = Color.fromRGBO(255, 255, 255, 0.10);

  /// Subtle chip / button fill (rgba(255,255,255,0.06)).
  static const Color fill = Color.fromRGBO(255, 255, 255, 0.06);

  /// Alert accent — ember red-orange, from oklch(0.67 0.19 34).
  static const Color alert = Color(0xFFE05A3A);

  /// Info accent — calm steel blue, from oklch(0.72 0.09 232).
  static const Color info = Color(0xFF5F9BD1);

  /// Behind a camera picture, which letterboxes rather than crops.
  static const Color pictureBackdrop = Color(0xFF000000);

  /// Accent for a notification of the given priority.
  static Color accentFor(bool isAlert) => isAlert ? alert : info;
}

class NotifRadii {
  NotifRadii._();

  /// Card corner radius (Direction 1B uses 30px; snapped to Hearth's card
  /// vocabulary at 26 for the smaller landscape canvas).
  static const double card = 26;

  /// Source chip / small button radius.
  static const double chip = 10;

  /// The dismiss button and pills.
  static const double pill = 999;
}

class NotifMotion {
  NotifMotion._();

  /// Entrance easing for the `riseUp` card animation and the ember pulse —
  /// cubic-bezier(.2,.8,.2,1) from the handoff.
  static const Cubic entrance = Cubic(0.2, 0.8, 0.2, 1.0);

  /// `riseUp` entrance duration (0.44s in the handoff).
  static const Duration entranceDuration = Duration(milliseconds: 440);

  /// Ember-glow pulse period for alert cards (2.6s).
  static const Duration emberPulse = Duration(milliseconds: 2600);

  /// How long the chime equalizer animates after a card arrives (~1.5s).
  static const Duration chimeWindow = Duration(milliseconds: 1500);

  /// riseUp translateY offset. Handoff is 38px portrait; re-mapped to the
  /// landscape canvas (~0.45 vertical ratio) → 18px.
  static const double riseOffset = 18;
}
