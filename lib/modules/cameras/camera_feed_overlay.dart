import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/idle_controller.dart';
import '../../app/tokens/tokens.dart';
import '../../config/hub_config.dart';
import '../../models/frigate_event.dart';
import '../../services/dlna/dlna_service.dart';
import '../../services/plex/livetv/plex_livetv_service.dart';
import '../../services/plex/plex_service.dart';
import '../../services/toast_service.dart';
import '../../services/video/hearth_video_player.dart';
import '../../utils/logger.dart';
import 'frigate_service.dart';

/// How long a feed may run before it returns to the previous screen, so one
/// left open can't play unattended on the display.
const Duration kCameraFeedMaxDuration = Duration(minutes: 5);

/// A request to show [camera]'s live feed, with the [frame] to show until video
/// appears.
class CameraFeedRequest {
  final String camera;
  final Uint8List? frame;

  const CameraFeedRequest({required this.camera, this.frame});
}

/// Whether a camera feed is open. Only one feed runs at a time.
class CameraFeedController extends StateNotifier<CameraFeedRequest?> {
  CameraFeedController() : super(null);

  void open(String camera, {Uint8List? frame}) {
    if (state != null) return;
    state = CameraFeedRequest(camera: camera, frame: frame);
  }

  void close() => state = null;
}

final cameraFeedProvider =
    StateNotifierProvider<CameraFeedController, CameraFeedRequest?>(
        (ref) => CameraFeedController());

/// Full-screen live view of a Frigate camera, opened by tapping a notification
/// card. Renders nothing when closed and sits above the notification deck, below
/// the alarm and cast overlays. Tap anywhere to return to what was showing.
class CameraFeedOverlay extends ConsumerWidget {
  final VoidCallback onWake;

  const CameraFeedOverlay({super.key, required this.onWake});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final request = ref.watch(cameraFeedProvider);
    if (request == null) return const SizedBox.shrink();

    WidgetsBinding.instance.addPostFrameCallback((_) => onWake());

    return Positioned.fill(
      child: _FeedView(key: ObjectKey(request), request: request),
    );
  }
}

class _FeedView extends ConsumerStatefulWidget {
  final CameraFeedRequest request;

  const _FeedView({super.key, required this.request});

  @override
  ConsumerState<_FeedView> createState() => _FeedViewState();
}

class _FeedViewState extends ConsumerState<_FeedView> {
  // Source-side stall detection, on the same timing as CamerasScreen: if Frigate
  // can't confirm the camera is producing frames for 12s, the feed closes.
  static const _stallPollInterval = Duration(seconds: 3);
  static const _stallPollLimit = 4;

  late final IdleController _idle;
  HearthVideoPlayer? _player;
  Timer? _maxDuration;
  Timer? _stallWatchdog;
  int _unhealthyPolls = 0;

  String get _camera => widget.request.camera;

  @override
  void initState() {
    super.initState();
    _idle = ref.read(idleControllerProvider);
    // After the frame, so an expanded camera screen has already collapsed: that
    // releases its decoder and unsuppresses idle, which must not undo ours.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _start();
    });
  }

  @override
  void dispose() {
    _maxDuration?.cancel();
    _stallWatchdog?.cancel();
    _player?.dispose();
    _idle.unsuppress();
    super.dispose();
  }

  Future<void> _start() async {
    _idle.suppress();
    _maxDuration = Timer(kCameraFeedMaxDuration, _close);

    final frigateUrl = ref.read(hubConfigProvider).frigateUrl;
    if (frigateUrl.isEmpty) {
      _closeWithToast('$_camera stream unavailable');
      return;
    }
    final HearthVideoPlayer player;
    try {
      player = HearthVideoPlayer.create();
    } catch (e) {
      Log.e('Cameras', 'video player failed for $_camera: $e');
      _closeWithToast('$_camera stream unavailable');
      return;
    }
    setState(() => _player = player);
    _stallWatchdog = Timer.periodic(_stallPollInterval, (_) => _checkStall());

    final playing =
        await player.play(FrigateCamera.fromEntry(_camera, frigateUrl).rtspUrl);
    if (mounted && !playing) {
      _closeWithToast('$_camera stream unavailable');
    }
  }

  Future<void> _checkStall() async {
    final fps = await ref.read(frigateServiceProvider).getCameraFps(_camera);
    if (!mounted) return;
    // Treat null (API failure) the same as 0, as CamerasScreen does.
    final healthy = fps != null && fps > 0.1;
    _unhealthyPolls = healthy ? 0 : _unhealthyPolls + 1;
    if (_unhealthyPolls >= _stallPollLimit) {
      Log.w('Cameras', '$_camera stalled at source, closing feed');
      _closeWithToast('$_camera stream offline');
    }
  }

  void _close() => ref.read(cameraFeedProvider.notifier).close();

  /// Closes first: the toast layer sits below this overlay.
  void _closeWithToast(String message) {
    _close();
    ref.read(toastProvider.notifier).show(
          message,
          icon: Icons.videocam_off,
          type: ToastType.warning,
        );
  }

  @override
  Widget build(BuildContext context) {
    // A cast takes over the screen and needs the decoder, so the feed gives way.
    ref.listen(dlnaRendererStateProvider, (_, next) {
      if (next.valueOrNull?.hasMedia ?? false) _close();
    });
    ref.listen(plexPlayerStateProvider, (_, next) {
      if (next.valueOrNull?.hasMedia ?? false) _close();
    });
    ref.listen(plexLiveTvStateProvider, (_, next) {
      if (next.valueOrNull?.hasMedia ?? false) _close();
    });

    final frame = widget.request.frame;
    final player = _player;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _close,
      child: ColoredBox(
        color: Colors.black, // theme-exempt: video
        child: Stack(
          fit: StackFit.expand,
          children: [
            // The card's latest picture, on screen at once while video connects.
            if (frame != null)
              Image.memory(frame, fit: BoxFit.contain, gaplessPlayback: true),
            if (player != null)
              ValueListenableBuilder<Size?>(
                valueListenable: player.videoSize,
                builder: (context, size, _) => size == null
                    ? const SizedBox.shrink()
                    : Stack(
                        fit: StackFit.expand,
                        children: [
                          player.buildView(fit: BoxFit.contain),
                          const Positioned(
                            top: HearthSpacing.x4,
                            right: HearthSpacing.x4,
                            child: _LiveBadge(),
                          ),
                        ],
                      ),
              ),
            Positioned(
              top: HearthSpacing.x4,
              left: HearthSpacing.x4,
              right: 96,
              child: Align(
                alignment: Alignment.centerLeft,
                child: _CameraLabel(name: _camera),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Camera name + back hint, matching the expanded view in CamerasScreen.
class _CameraLabel extends StatelessWidget {
  final String name;

  const _CameraLabel({required this.name});

  @override
  Widget build(BuildContext context) {
    return Container(
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
          Flexible(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 14, color: Colors.white70), // theme-exempt: video
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
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
    );
  }
}
