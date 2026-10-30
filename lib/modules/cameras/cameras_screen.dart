import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/frigate_event.dart';
import '../../app/idle_controller.dart';
import '../../app/tokens/tokens.dart';
import '../../services/toast_service.dart';
import '../../services/video/hearth_video_player.dart';
import '../../utils/logger.dart';
import 'camera_feed_overlay.dart';
import 'frigate_service.dart';
import '../../app/theme/hearth_colors.dart';
import '../../widgets/themed_background.dart';

/// Columns for a grid of 16:9 camera tiles in a [box]-sized area.
///
/// Landscape keeps the layout the screen was designed around. A portrait box
/// is too narrow for three tiles to stay legible, so it drops a column — and
/// one or two cameras stack rather than leave most of the height empty.
int cameraGridColumns(int cameraCount, Size box) {
  if (box.width < box.height) return cameraCount <= 2 ? 1 : 2;
  return cameraCount <= 4 ? 2 : 3;
}

/// Camera grid screen with live video expansion.
///
/// Two viewing modes:
/// 1. Grid — snapshot thumbnails from Frigate's `/latest.jpg` endpoint,
///    auto-refreshed every 3 seconds via a cache-busting query parameter.
/// 2. Expanded — tapping a tile opens full-screen RTSP video via media_kit
///    (libmpv on desktop, GStreamer on Pi). Tap anywhere to return to grid.
class CamerasScreen extends ConsumerStatefulWidget {
  final bool isActive;
  const CamerasScreen({super.key, this.isActive = false});

  @override
  ConsumerState<CamerasScreen> createState() => _CamerasScreenState();
}

class _CamerasScreenState extends ConsumerState<CamerasScreen> {
  /// Which camera is currently expanded for full-screen video, or null for grid.
  FrigateCamera? _expandedCamera;

  HearthVideoPlayer? _videoPlayer;

  // --- Source-side stall detection ---
  // Polls Frigate's /api/stats for the expanded camera's `camera_fps` every
  // [_stallPollInterval]. If fps reads as 0 (or the request fails) for
  // [_stallGrace] consecutive time, we treat the stream as stalled at the
  // source and collapse back to the grid with a toast.
  //
  // This detects camera-side failures (offline camera, crashed ffmpeg, dead
  // capture thread) without touching the GStreamer pipeline. It does NOT
  // detect downstream decoder-side stalls — those are rare, and the
  // swipe-away dispose in didUpdateWidget already prevents them from wedging
  // flutter-pi.
  static const _stallPollInterval = Duration(seconds: 3);
  static const _stallGrace = Duration(seconds: 10);
  Timer? _stallWatchdog;
  DateTime? _lastHealthyAt;

  @override
  void didUpdateWidget(covariant CamerasScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Releasing the video player the moment we're swiped off-screen avoids
    // keeping GStreamer V4L2 decode buffers (and their DMA-BUF fences) alive
    // while the page is invisible. A stalled RTSP decoder in the background
    // can wedge flutter-pi's raster thread on an unsignalled fence.
    if (oldWidget.isActive && !widget.isActive && _expandedCamera != null) {
      // Direct mutation (no setState) because didUpdateWidget runs inside
      // the parent's build phase; setState here would throw.
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

  /// Opens full-screen view for the given camera with live RTSP video.
  void _expandCamera(FrigateCamera camera) {
    _disposePlayer();
    try {
      ref.read(idleControllerProvider).suppress();
      final player = HearthVideoPlayer.create();
      player.play(camera.rtspUrl);
      setState(() {
        _expandedCamera = camera;
        _videoPlayer = player;
      });
      _startStallWatchdog(camera);
    } catch (e) {
      ref.read(idleControllerProvider).unsuppress();
      setState(() {
        _expandedCamera = camera;
      });
    }
  }

  /// Returns to the grid view and cleans up the video player.
  void _collapseCamera() {
    _disposePlayer();
    ref.read(idleControllerProvider).unsuppress();
    setState(() => _expandedCamera = null);
  }

  void _disposePlayer() {
    _stopStallWatchdog();
    _videoPlayer?.dispose();
    _videoPlayer = null;
  }

  void _startStallWatchdog(FrigateCamera camera) {
    _stopStallWatchdog();
    _lastHealthyAt = DateTime.now();
    _stallWatchdog = Timer.periodic(_stallPollInterval, (_) async {
      if (!mounted || _expandedCamera?.name != camera.name) return;
      final fps = await ref
          .read(frigateServiceProvider)
          .getCameraFps(camera.name);
      if (!mounted || _expandedCamera?.name != camera.name) return;
      // Treat null (API failure) the same as 0 — if we can't confirm the
      // camera is healthy, we can't confirm it's streaming either.
      final healthy = fps != null && fps > 0.1;
      if (healthy) {
        _lastHealthyAt = DateTime.now();
        return;
      }
      final stalledFor = DateTime.now().difference(_lastHealthyAt!);
      if (stalledFor >= _stallGrace) {
        Log.w('Cameras',
            '${camera.name} stalled at source (${stalledFor.inSeconds}s), collapsing');
        ref.read(toastProvider.notifier).show(
              '${camera.name} stream offline',
              icon: Icons.videocam_off,
              type: ToastType.warning,
            );
        _collapseCamera();
      }
    });
  }

  void _stopStallWatchdog() {
    _stallWatchdog?.cancel();
    _stallWatchdog = null;
    _lastHealthyAt = null;
  }

  @override
  Widget build(BuildContext context) {
    // Only one RTSP decoder runs at a time, so a feed opened from a notification
    // card takes over from an expanded camera.
    ref.listen(cameraFeedProvider, (_, next) {
      if (next != null && _expandedCamera != null) _collapseCamera();
    });

    final frigate = ref.watch(frigateServiceProvider);
    final cameras = frigate.cameras;

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
              Text('Connect Frigate NVR in settings',
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
              // Show snapshot as placeholder while video loads
              _CameraSnapshotTile(
                camera: _expandedCamera!,
                isActive: true,
                fit: BoxFit.contain,
              ),
              // Video layers on top once playing
              if (_videoPlayer != null)
                _videoPlayer!.buildView(fit: BoxFit.contain),
              // Camera name + back hint overlay
              Positioned(
                top: HearthSpacing.x4,
                left: HearthSpacing.x4,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: HearthSpacing.x3, vertical: 6),
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
              // Live indicator
              Positioned(
                top: HearthSpacing.x4,
                right: HearthSpacing.x4,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: HearthSpacing.x2, vertical: HearthSpacing.x1),
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
                    // Auto-refreshing snapshot tile
                    _CameraSnapshotTile(
                      camera: camera,
                      isActive: widget.isActive,
                    ),
                    // Play icon hint
                    Center(
                      child: Icon(Icons.play_circle_outline,
                        size: 40,
                        color: c.textMuted),
                    ),
                    // Camera name label with gradient background
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

/// A single camera snapshot tile that auto-refreshes every 3 seconds.
///
/// Uses a cache-busting query parameter (current timestamp) to force
/// Image.network to fetch a fresh frame from Frigate's `/latest.jpg`
/// endpoint. The old image stays visible while the new one loads,
/// so there's no flicker between refreshes.
class _CameraSnapshotTile extends StatefulWidget {
  final FrigateCamera camera;
  final bool isActive;
  final BoxFit fit;
  const _CameraSnapshotTile({required this.camera, this.isActive = false, this.fit = BoxFit.cover});

  @override
  State<_CameraSnapshotTile> createState() => _CameraSnapshotTileState();
}

class _CameraSnapshotTileState extends State<_CameraSnapshotTile> {
  Timer? _refreshTimer;

  /// Cache-buster value appended to the snapshot URL.
  /// Changing this forces Image.network to re-fetch.
  int _tick = DateTime.now().millisecondsSinceEpoch;

  /// The full snapshot URL for the current tick, used to evict
  /// the previous entry from Flutter's image cache on refresh.
  String get _snapshotUrl => '${widget.camera.snapshotUrl}?t=$_tick';

  @override
  void initState() {
    super.initState();
    if (widget.isActive) _startTimer();
  }

  @override
  void didUpdateWidget(_CameraSnapshotTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      // Becoming visible — refresh immediately and start polling
      _evictAndRefresh();
      _startTimer();
    } else if (!widget.isActive && oldWidget.isActive) {
      _refreshTimer?.cancel();
      _refreshTimer = null;
    }
  }

  void _startTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) _evictAndRefresh();
    });
  }

  /// Evict the current snapshot URL from Flutter's image cache,
  /// then update the tick so the next build fetches a fresh frame.
  void _evictAndRefresh() {
    final oldUrl = _snapshotUrl;
    setState(() => _tick = DateTime.now().millisecondsSinceEpoch);
    PaintingBinding.instance.imageCache.evict(oldUrl);
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Image.network(
      // Append timestamp to bust the HTTP cache and get a fresh frame
      _snapshotUrl,
      fit: widget.fit,
      // Keep the previous frame visible while the new one loads
      gaplessPlayback: true,
      // Cap decoded texture size to tile display resolution (~300px wide)
      cacheWidth: 300,
      errorBuilder: (_, __, ___) => Container(
        color: context.hearthColors.inkAt(0.05),
        child: Center(
          child: Icon(Icons.videocam_off, color: context.hearthColors.inkAt(0.24)),
        ),
      ),
    );
  }
}
