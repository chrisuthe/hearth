import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/idle_controller.dart';
import '../../../app/theme/hearth_colors.dart';
import '../../../app/tokens/tokens.dart';
import '../camera_feed_overlay.dart';
import 'doorbell_call_controller.dart';
import 'rtc_client.dart';

/// The doorbell call view: live video and audio from the doorbell, a large
/// Talk toggle and Hang up. Opened by a ring (see [DoorbellCallController]);
/// renders nothing otherwise.
///
/// Unlike the camera feed, a tap on the video does not close it. It sits
/// above the cast overlays, so a cast can't hide a live microphone, and
/// below the alarm.
class DoorbellCallOverlay extends ConsumerWidget {
  final VoidCallback onWake;

  const DoorbellCallOverlay({super.key, required this.onWake});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(doorbellCallProvider);
    if (call == null) return const SizedBox.shrink();

    WidgetsBinding.instance.addPostFrameCallback((_) => onWake());

    return Positioned.fill(
      child: _CallView(key: ObjectKey(call.session), call: call),
    );
  }
}

class _CallView extends ConsumerStatefulWidget {
  final DoorbellCall call;

  const _CallView({super.key, required this.call});

  @override
  ConsumerState<_CallView> createState() => _CallViewState();
}

class _CallViewState extends ConsumerState<_CallView> {
  late final IdleController _idle;
  bool _toggling = false;

  @override
  void initState() {
    super.initState();
    _idle = ref.read(idleControllerProvider)..suppress();
  }

  @override
  void dispose() {
    _idle.unsuppress();
    super.dispose();
  }

  Future<void> _toggleTalk() async {
    if (_toggling) return;
    setState(() => _toggling = true);
    try {
      await ref
          .read(doorbellCallProvider.notifier)
          .setTalk(!widget.call.talkOn);
    } finally {
      if (mounted) setState(() => _toggling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final call = widget.call;
    return ColoredBox(
      color: Colors.black, // theme-exempt: video
      child: Stack(
        fit: StackFit.expand,
        children: [
          ValueListenableBuilder<RtcReceiveLink?>(
            valueListenable: call.session.media,
            builder: (context, link, _) => link == null
                ? const Center(child: _Connecting())
                : link.buildView(),
          ),
          Positioned(
            top: HearthSpacing.x4,
            left: HearthSpacing.x4,
            right: HearthSpacing.x4,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _CallLabel(name: call.camera),
            ),
          ),
          Positioned(
            left: HearthSpacing.x6,
            right: HearthSpacing.x6,
            bottom: HearthSpacing.x8,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (call.notice != null) ...[
                  FeedNotice(call.notice!),
                  const SizedBox(height: HearthSpacing.x4),
                ],
                _Controls(
                  talkOn: call.talkOn,
                  busy: _toggling || !call.connected,
                  onTalk: _toggleTalk,
                  onHangUp: ref.read(doorbellCallProvider.notifier).hangUp,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Talk and Hang up, side by side, stacked when the screen is too narrow.
class _Controls extends StatelessWidget {
  final bool talkOn;
  final bool busy;
  final VoidCallback onTalk;
  final VoidCallback onHangUp;

  const _Controls({
    required this.talkOn,
    required this.busy,
    required this.onTalk,
    required this.onHangUp,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.hearthColors;
    final talk = _BigButton(
      key: const Key('doorbell-talk'),
      icon: talkOn ? Icons.mic : Icons.mic_none,
      label: talkOn ? 'Talking' : 'Talk',
      fill: talkOn ? colors.accentFill : colors.raised,
      ink: talkOn ? colors.onAccent : colors.text,
      busy: busy,
      live: talkOn,
      onTap: busy ? null : onTalk,
    );
    final hangUp = _BigButton(
      key: const Key('doorbell-hangup'),
      icon: Icons.call_end,
      label: 'Hang up',
      fill: colors.danger,
      ink: Colors.white, // theme-exempt: video
      onTap: onHangUp,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 560) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              talk,
              const SizedBox(height: HearthSpacing.x4),
              hangUp,
            ],
          );
        }
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(width: 320, child: talk),
            const SizedBox(width: HearthSpacing.x6),
            SizedBox(width: 240, child: hangUp),
          ],
        );
      },
    );
  }
}

/// A button readable from across a kitchen: 96 px tall, large type.
class _BigButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color fill;
  final Color ink;
  final bool busy;
  final bool live;
  final VoidCallback? onTap;

  const _BigButton({
    super.key,
    required this.icon,
    required this.label,
    required this.fill,
    required this.ink,
    this.busy = false,
    this.live = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      toggled: live,
      label: label,
      child: Material(
        color: fill,
        borderRadius: BorderRadius.circular(48),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 96,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (busy)
                  SizedBox(
                    width: HearthIcon.lg,
                    height: HearthIcon.lg,
                    child: CircularProgressIndicator(
                        strokeWidth: 3, color: ink),
                  )
                else
                  Icon(icon, size: HearthIcon.xl, color: ink),
                const SizedBox(width: HearthSpacing.x3),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: HearthFont.headline,
                      fontWeight: FontWeight.w600,
                      color: ink,
                    ),
                  ),
                ),
                if (live) ...[
                  const SizedBox(width: HearthSpacing.x3),
                  Icon(Icons.circle, size: HearthIcon.xs, color: ink),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CallLabel extends StatelessWidget {
  final String name;

  const _CallLabel({required this.name});

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
          const Icon(Icons.doorbell_outlined,
              size: HearthIcon.sm, color: Colors.white70), // theme-exempt: video
          const SizedBox(width: HearthSpacing.x2),
          Flexible(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: HearthFont.bodyLg,
                  color: Colors.white), // theme-exempt: video
            ),
          ),
        ],
      ),
    );
  }
}

class _Connecting extends StatelessWidget {
  const _Connecting();

  @override
  Widget build(BuildContext context) {
    return const Text(
      'Connecting…',
      style: TextStyle(
          fontSize: HearthFont.title,
          color: Colors.white70), // theme-exempt: video
    );
  }
}
