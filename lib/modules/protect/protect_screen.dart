import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/idle_controller.dart';
import '../../app/tokens/tokens.dart';
import '../../models/protect_camera.dart';
import '../../services/toast_service.dart';
import '../../services/video/hearth_video_player.dart';
import '../../utils/logger.dart';
import '../cameras/camera_feed_overlay.dart';
import '../cameras/cameras_screen.dart' show cameraGridColumns;
import 'protect_service.dart';
import '../../app/theme/hearth_colors.dart';
import '../../widgets/themed_background.dart';

/// UniFi Protect camera grid with live video expansion.
///
/// Mirrors the Frigate [CamerasScreen] pattern:
/// 1. Grid — snapshot thumbnails fetched as authenticated bytes from Protect's
///    `/cameras/{id}/snapshot` endpoint, auto-refreshed every 3 seconds.
/// 2. Expanded — tapping a tile resolves an RTSPS URL (POST rtsps-stream) and
///    plays it full-screen via media_kit / GStreamer. Tap anywhere to return.
class ProtectScreen extends ConsumerStatefulWidget {
  final bool isActive;
  const ProtectScreen({super.key, this.isActive = false});

  @override
  ConsumerState<ProtectScreen> createState() => _ProtectScreenState();
}

class _ProtectScreenState extends ConsumerState<ProtectScreen> {
  /// Which camera is currently expanded for full-screen video, or null for grid.
  ProtectCamera? _expandedCamera;

  HearthVideoPlayer? _videoPlayer;

  @override
  void didUpdateWidget(covariant ProtectScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Release the video player the moment we're swiped off-screen — a stalled
    // RTSP decoder left alive in the background can wedge flutter-pi's raster
    // thread. Direct mutation (no setState) because didUpdateWidget runs inside
    // the parent's build phase.
    if (oldWidget.isActive && !widget.isActive && _expandedCamera != null) {
      _disposePlayer();
      ref.read(idleControllerProvider).unsuppress();
      _expandedCamera = null;
    }
  }

  @override
  void dispose() {
    _disposePlayer();
    super.dispose();
  }

  /// Opens full-screen view for [camera]: shows its snapshot immediately, then
  /// resolves the RTSPS URL and starts live video once it arrives.
  Future<void> _expandCamera(ProtectCamera camera) async {
    _disposePlayer();
    ref.read(idleControllerProvider).suppress();
    setState(() => _expandedCamera = camera);

    final url = await ref.read(protectServiceProvider).getStreamUrl(camera.id);
    // Bail if the user swiped away or collapsed while we were awaiting.
    if (!mounted || _expandedCamera?.id != camera.id) return;
    if (url == null) {
      ref.read(toastProvider.notifier).show(
            '${camera.name} stream unavailable',
            icon: Icons.videocam_off,
            type: ToastType.warning,
          );
      return; // Snapshot placeholder stays visible.
    }
    try {
      final player = HearthVideoPlayer.create();
      player.play(url);
      setState(() => _videoPlayer = player);
    } catch (e) {
      Log.e('Protect', 'video player failed for ${camera.name}: $e');
    }
  }

  /// Returns to the grid view and cleans up the video player.
  void _collapseCamera() {
    _disposePlayer();
    ref.read(idleControllerProvider).unsuppress();
    setState(() => _expandedCamera = null);
  }

  void _disposePlayer() {
    _videoPlayer?.dispose();
    _videoPlayer = null;
  }

  @override
  Widget build(BuildContext context) {
    // Only one RTSP decoder runs at a time, so a feed opened from a notification
    // card takes over from an expanded camera.
    ref.listen(cameraFeedProvider, (_, next) {
      if (next != null && _expandedCamera != null) _collapseCamera();
    });

    final cameras = ref.watch(protectServiceProvider).cameras;

    // --- Empty state ---
    if (cameras.isEmpty) {
      final c = context.hearthColors;
      return ThemedBackground.photo(
        strength: TintStrength.medium,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.videocam_off, size: HearthIcon.xxl,
                  color: c.inkAt(0.2)),
              const SizedBox(height: HearthSpacing.x4),
              Text('No cameras',
                  style: TextStyle(
                      fontSize: HearthFont.bodyLg,
                      color: c.textMuted)),
              const SizedBox(height: HearthSpacing.x2),
              Text('Connect UniFi Protect in settings',
                  style: TextStyle(
                      fontSize: 14,
                      color: c.textMuted)),
            ],
          ),
        ),
      );
    }

    // --- Expanded: full-screen video or snapshot ---
    if (_expandedCamera != null) {
      return GestureDetector(
        onTap: _collapseCamera,
        child: Container(
          color: Colors.black, // theme-exempt: video
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Snapshot placeholder while the RTSPS stream resolves and loads.
              _ProtectSnapshotTile(
                camera: _expandedCamera!,
                isActive: true,
                fit: BoxFit.contain,
              ),
              // Video layers on top once playing.
              if (_videoPlayer != null)
                _videoPlayer!.buildView(fit: BoxFit.contain),
              // Camera name + back hint overlay.
              Positioned(
                top: HearthSpacing.x4,
                left: HearthSpacing.x4,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: HearthSpacing.x3, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54, // theme-exempt: video
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.arrow_back,
                          size: HearthIcon.xs, color: Colors.white70), // theme-exempt: video
                      const SizedBox(width: 6),
                      Text(_expandedCamera!.name,
                          style: const TextStyle(
                              fontSize: 14, color: Colors.white70)), // theme-exempt: video
                    ],
                  ),
                ),
              ),
              // Live indicator (only once video is actually playing).
              if (_videoPlayer != null)
                Positioned(
                  top: HearthSpacing.x4,
                  right: HearthSpacing.x4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: HearthSpacing.x2, vertical: HearthSpacing.x1),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.8), // theme-exempt: video
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.circle, size: 8, color: Colors.white), // theme-exempt: video
                        SizedBox(width: HearthSpacing.x1),
                        Text('LIVE',
                            style: TextStyle(
                                fontSize: HearthFont.caption,
                                fontWeight: FontWeight.w600,
                                color: Colors.white)), // theme-exempt: video
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    // --- Grid view: auto-refreshing snapshot tiles ---
    final c = context.hearthColors;
    return ThemedBackground.photo(
      strength: TintStrength.medium,
      child: LayoutBuilder(builder: (context, constraints) => GridView.builder(
        padding: const EdgeInsets.all(HearthSpacing.x4),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cameraGridColumns(cameras.length, constraints.biggest),
          crossAxisSpacing: HearthSpacing.x3,
          mainAxisSpacing: HearthSpacing.x3,
          childAspectRatio: 16 / 9,
        ),
        itemCount: cameras.length,
        itemBuilder: (context, index) {
          final camera = cameras[index];
          return ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => _expandCamera(camera),
                splashColor: c.inkAt(0.24),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _ProtectSnapshotTile(
                      camera: camera,
                      isActive: widget.isActive,
                    ),
                    Center(
                      child: Icon(Icons.play_circle_outline,
                          size: 40,
                          color: c.textMuted),
                    ),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              c.canvasAt(0.7),
                            ],
                          ),
                        ),
                        child: Text(camera.name,
                            style: TextStyle(
                                fontSize: 12, color: c.textSecondary)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      )),
    );
  }
}

/// A single Protect snapshot tile that auto-refreshes every 3 seconds.
///
/// Unlike Frigate's open `latest.jpg`, Protect snapshots need the `X-API-Key`
/// header and acceptance of the console's self-signed cert — so the frame is
/// fetched as bytes through [ProtectService] and rendered with `Image.memory`.
/// The previous frame stays on screen until the next fetch completes, so
/// refreshes don't flicker.
class _ProtectSnapshotTile extends ConsumerStatefulWidget {
  final ProtectCamera camera;
  final bool isActive;
  final BoxFit fit;
  const _ProtectSnapshotTile(
      {required this.camera, this.isActive = false, this.fit = BoxFit.cover});

  @override
  ConsumerState<_ProtectSnapshotTile> createState() =>
      _ProtectSnapshotTileState();
}

class _ProtectSnapshotTileState extends ConsumerState<_ProtectSnapshotTile> {
  Timer? _refreshTimer;
  Uint8List? _bytes;
  bool _fetching = false;

  @override
  void initState() {
    super.initState();
    if (widget.isActive) {
      _refresh();
      _startTimer();
    }
  }

  @override
  void didUpdateWidget(_ProtectSnapshotTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _refresh();
      _startTimer();
    } else if (!widget.isActive && oldWidget.isActive) {
      _refreshTimer?.cancel();
      _refreshTimer = null;
    }
  }

  void _startTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) _refresh();
    });
  }

  /// Fetch a fresh frame, keeping the previous one visible until it arrives.
  /// Skips overlapping fetches so a slow console doesn't queue up requests.
  Future<void> _refresh() async {
    if (_fetching) return;
    _fetching = true;
    try {
      final bytes =
          await ref.read(protectServiceProvider).snapshotBytes(widget.camera.id);
      if (mounted && bytes != null) setState(() => _bytes = bytes);
    } finally {
      _fetching = false;
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.hearthColors;
    final bytes = _bytes;
    if (bytes == null) {
      return Container(color: c.inkAt(0.05));
    }
    return Image.memory(
      bytes,
      fit: widget.fit,
      gaplessPlayback: true,
      cacheWidth: 300,
      errorBuilder: (_, _, _) => Container(
        color: c.inkAt(0.05),
        child: Center(
          child: Icon(Icons.videocam_off, color: c.inkAt(0.24)),
        ),
      ),
    );
  }
}
