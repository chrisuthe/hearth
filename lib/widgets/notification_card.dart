import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../app/tokens/notification_tokens.dart';
import '../app/tokens/tokens.dart';
import '../models/hearth_notification.dart';
import '../services/notification_service.dart' show kTransientNotificationLifetime;
import 'notification_picture.dart';

/// The shared notification card ("The Notification Card" in the handoff).
///
/// Renders the source chip, priority dot + label, timestamp, dismiss button,
/// title + body, a chime equalizer (animated only during the ~1.5s window
/// after arrival), a per-card mute toggle, a sticky/transient tag pill, and —
/// for transient cards — a 6s countdown bar. A notification with an `image`
/// shows it above all of that.
///
/// Dismissal (the ✕ button, swipe) is driven by [onDismiss]; the countdown bar
/// is a visual indicator only — `NotificationService`'s Dart timer owns the
/// actual auto-dismiss.
class NotificationCard extends StatefulWidget {
  final HearthNotification notification;
  final VoidCallback onDismiss;

  /// Makes the card tappable, called with its latest picture if it has one.
  final ValueChanged<Uint8List?>? onOpenFeed;

  const NotificationCard({
    super.key,
    required this.notification,
    required this.onDismiss,
    this.onOpenFeed,
  });

  @override
  State<NotificationCard> createState() => _NotificationCardState();
}

class _NotificationCardState extends State<NotificationCard>
    with TickerProviderStateMixin {
  late final AnimationController _eqController;
  AnimationController? _emberController;
  Timer? _chimeTimer;
  bool _chiming = false;
  late bool _muted;

  /// Handed to the feed when the card is tapped. Nothing here rebuilds from it.
  Uint8List? _latestFrame;

  bool get _isAlert =>
      widget.notification.priority == NotificationPriority.alert;

  @override
  void initState() {
    super.initState();
    _muted = widget.notification.muted;

    // Equalizer bars pulse while the chime plays; stop after the chime window.
    _eqController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    if (!_muted) {
      _chiming = true;
      _eqController.repeat(reverse: true);
      _chimeTimer = Timer(NotifMotion.chimeWindow, () {
        if (!mounted) return;
        setState(() => _chiming = false);
        _eqController.stop();
      });
    }

    // Alert cards get a slow pulsing ember glow.
    if (_isAlert) {
      _emberController = AnimationController(
        vsync: this,
        duration: NotifMotion.emberPulse,
      )..repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _chimeTimer?.cancel();
    _eqController.dispose();
    _emberController?.dispose();
    super.dispose();
  }

  void _toggleMute() {
    setState(() {
      _muted = !_muted;
      if (_muted) {
        _chiming = false;
        _eqController.stop();
        _chimeTimer?.cancel();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.notification;
    final accent = NotifColors.accentFor(_isAlert);
    final card = _buildCard(n, accent);

    // Ember pulse: an animated outer glow layered behind the card for alerts.
    if (_emberController == null) return card;
    return AnimatedBuilder(
      animation: _emberController!,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_emberController!.value);
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(NotifRadii.card),
            boxShadow: [
              BoxShadow(
                color: accent.withValues(alpha: 0.10 + 0.28 * t),
                blurRadius: 24 + 22 * t,
                spreadRadius: 1,
              ),
            ],
          ),
          child: child,
        );
      },
      child: card,
    );
  }

  Widget _buildCard(HearthNotification n, Color accent) {
    final onOpenFeed = widget.onOpenFeed;
    final card = _buildSurface(n, accent);
    if (onOpenFeed == null) return card;
    return GestureDetector(
      onTap: () => onOpenFeed(_latestFrame),
      child: card,
    );
  }

  Widget _buildSurface(HearthNotification n, Color accent) {
    final image = n.image;
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(
        HearthSpacing.x6,
        HearthSpacing.x5,
        HearthSpacing.x5,
        HearthSpacing.x5,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _metaRow(n, accent),
          const SizedBox(height: HearthSpacing.x3),
          _content(n),
          const SizedBox(height: HearthSpacing.x4),
          _chimeRow(n),
          if (!n.sticky) ...[
            const SizedBox(height: HearthSpacing.x3),
            const _CountdownBar(),
          ],
        ],
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(NotifRadii.card),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          decoration: BoxDecoration(
            color: NotifColors.cardGlass,
            borderRadius: BorderRadius.circular(NotifRadii.card),
            border: Border.all(
              color: _isAlert
                  ? accent.withValues(alpha: 0.85)
                  : NotifColors.hairline,
              width: _isAlert ? 1.6 : 1,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color.fromRGBO(0, 0, 0, 0.55),
                blurRadius: 40,
                offset: Offset(0, 18),
              ),
            ],
          ),
          child: Stack(
            children: [
              if (image == null)
                content
              else
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    NotificationPicture(
                      image: image,
                      refresh: n.imageRefresh,
                      showPlayIcon: widget.onOpenFeed != null,
                      onFrame: (frame) => _latestFrame = frame,
                    ),
                    content,
                  ],
                ),
              // Left accent rail, painted over the picture.
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: Container(
                  width: 5,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: const BorderRadius.horizontal(
                      left: Radius.circular(NotifRadii.card),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Row 1 — source chip · priority dot + label · spacer · time · dismiss ✕
  Widget _metaRow(HearthNotification n, Color accent) {
    return Row(
      children: [
        Flexible(child: _sourceChip(n.sourceLabel)),
        const SizedBox(width: HearthSpacing.x3),
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            color: accent,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: accent.withValues(alpha: 0.7), blurRadius: 12),
            ],
          ),
        ),
        const SizedBox(width: HearthSpacing.x2),
        Text(
          _isAlert ? 'ALERT' : 'INFO',
          style: const TextStyle(
            fontSize: HearthFont.caption,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.5,
            color: NotifColors.textMuted,
          ),
        ),
        const Spacer(),
        Text(
          _formatTime(n.timestamp),
          style: const TextStyle(
            fontSize: HearthFont.label,
            color: NotifColors.textDim,
          ),
        ),
        const SizedBox(width: HearthSpacing.x3),
        _iconButton(Icons.close, widget.onDismiss),
      ],
    );
  }

  Widget _sourceChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: HearthSpacing.x2, vertical: HearthSpacing.x1),
      decoration: BoxDecoration(
        color: NotifColors.fill,
        borderRadius: BorderRadius.circular(NotifRadii.chip),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: HearthFont.caption,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
          color: NotifColors.text,
        ),
      ),
    );
  }

  // Row 2 — title + body
  Widget _content(HearthNotification n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          n.title,
          style: const TextStyle(
            fontSize: HearthFont.titleLg,
            fontWeight: FontWeight.w700,
            height: 1.15,
            color: NotifColors.text,
          ),
        ),
        if (n.body.isNotEmpty) ...[
          const SizedBox(height: HearthSpacing.x1),
          Text(
            n.body,
            style: const TextStyle(
              fontSize: HearthFont.bodyLg,
              color: NotifColors.textMuted,
            ),
          ),
        ],
      ],
    );
  }

  // Row 4 — equalizer + chime label · spacer · mute · sticky/transient tag
  Widget _chimeRow(HearthNotification n) {
    final chimeLabel = _muted ? 'Muted' : n.chimeLabel;
    return Row(
      children: [
        if (_chiming && !_muted) ...[
          _Equalizer(controller: _eqController),
          const SizedBox(width: HearthSpacing.x2),
        ],
        Text(
          chimeLabel,
          style: const TextStyle(
            fontSize: HearthFont.label,
            color: NotifColors.textMuted,
          ),
        ),
        const Spacer(),
        _ghostButton(_muted ? 'Unmute' : 'Mute', _toggleMute),
        const SizedBox(width: HearthSpacing.x2),
        _tagPill(widget.onOpenFeed != null
            ? 'Tap for live view'
            : n.sticky
                ? 'Sticky'
                : 'Auto · 6s'),
      ],
    );
  }

  Widget _tagPill(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: HearthSpacing.x2, vertical: 3),
      decoration: BoxDecoration(
        color: NotifColors.fill,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: HearthFont.caption,
          color: NotifColors.textDim,
        ),
      ),
    );
  }

  Widget _ghostButton(String label, VoidCallback onTap) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(NotifRadii.chip),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: HearthSpacing.x3, vertical: HearthSpacing.x1),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: HearthFont.label,
              color: NotifColors.textMuted,
            ),
          ),
        ),
      ),
    );
  }

  Widget _iconButton(IconData icon, VoidCallback onTap) {
    return Material(
      color: NotifColors.fill,
      shape: const CircleBorder(
        side: BorderSide(color: NotifColors.hairline),
      ),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(HearthSpacing.x2),
          child: Icon(icon, size: HearthIcon.sm, color: NotifColors.text),
        ),
      ),
    );
  }

  static String _formatTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

/// Three-bar equalizer that animates while the chime plays. Bars rise and fall
/// out of phase (staggered), matching the handoff `eq` animation.
class _Equalizer extends StatelessWidget {
  final AnimationController controller;

  const _Equalizer({required this.controller});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 15,
      height: 16,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(3, (i) {
          return AnimatedBuilder(
            animation: controller,
            builder: (context, _) {
              // Stagger each bar by a third of the cycle.
              final phase = (controller.value + i / 3) % 1.0;
              final t = (0.5 - (phase - 0.5).abs()) * 2; // triangle 0..1..0
              final height = 5 + 11 * t;
              return Container(
                width: 3,
                height: height,
                decoration: BoxDecoration(
                  color: NotifColors.textMuted,
                  borderRadius: BorderRadius.circular(2),
                ),
              );
            },
          );
        }),
      ),
    );
  }
}

/// Transient countdown bar — a 4px track whose inner fill shrinks 100%→0 over
/// 6s. Visual only; the actual auto-dismiss is driven by the service timer.
class _CountdownBar extends StatelessWidget {
  const _CountdownBar();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 4,
        child: Stack(
          children: [
            const Positioned.fill(
              child: ColoredBox(color: NotifColors.hairline),
            ),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 1, end: 0),
              duration: kTransientNotificationLifetime,
              child: const ColoredBox(color: NotifColors.textMuted),
              builder: (context, value, child) {
                return FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: value.clamp(0.0, 1.0),
                  child: child,
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
