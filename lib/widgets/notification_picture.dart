import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/tokens/notification_tokens.dart';
import '../app/tokens/tokens.dart';
import '../modules/cameras/camera_feed_overlay.dart';
import '../services/notification_image_loader.dart';

/// The picture on a notification card, re-fetched every [refresh] when set.
///
/// The previous frame stays on screen until the next fetch completes, and a
/// failed refresh keeps it. A picture that has never loaded takes no space, so
/// the card reads as text only. Polling skips while a camera feed is open and
/// stops with the card.
///
/// The whole frame stays visible because doorbells are often 4:3 or taller, and
/// cropping one to the box could cut off a face.
class NotificationPicture extends ConsumerStatefulWidget {
  final String image;
  final Duration? refresh;
  final bool showPlayIcon;
  final ValueChanged<Uint8List>? onFrame;

  const NotificationPicture({
    super.key,
    required this.image,
    this.refresh,
    this.showPlayIcon = false,
    this.onFrame,
  });

  @override
  ConsumerState<NotificationPicture> createState() =>
      _NotificationPictureState();
}

class _NotificationPictureState extends ConsumerState<NotificationPicture> {
  Timer? _refreshTimer;
  Uint8List? _frame;
  bool _fetching = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _fetch();
    _startTimer();
  }

  @override
  void didUpdateWidget(NotificationPicture oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.image != oldWidget.image) {
      _frame = null;
      _failed = false;
      _fetching = false;
      _fetch();
    }
    if (widget.refresh != oldWidget.refresh) _startTimer();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _startTimer() {
    _refreshTimer?.cancel();
    final refresh = widget.refresh;
    if (refresh == null) return;
    _refreshTimer = Timer.periodic(refresh, (_) {
      if (ref.read(cameraFeedProvider) == null) _fetch();
    });
  }

  /// Skips overlapping fetches, so a slow camera doesn't queue up requests.
  Future<void> _fetch() async {
    if (_fetching) return;
    _fetching = true;
    final image = widget.image;
    final frame = await ref.read(notificationImageLoaderProvider).fetch(image);
    // The address changed while this was in flight, so its result is stale.
    if (!mounted || image != widget.image) return;
    _fetching = false;
    if (frame != null) {
      setState(() {
        _frame = frame;
        _failed = false;
      });
      widget.onFrame?.call(frame);
    } else if (_frame == null) {
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return const SizedBox.shrink();
    final frame = _frame;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.5;
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      return SizedBox(
        width: width,
        height: math.min(width * 9 / 16, maxHeight),
        child: ColoredBox(
          color: NotifColors.pictureBackdrop,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (frame != null)
                Image.memory(
                  frame,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  cacheWidth: (width * pixelRatio).round(),
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              if (widget.showPlayIcon)
                const Center(
                  child: Icon(
                    Icons.play_circle_outline,
                    size: HearthIcon.xxl,
                    color: NotifColors.text,
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }
}
