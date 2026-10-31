import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../app/tokens/tokens.dart';
import 'alarm_service.dart';
import 'sunrise_controller.dart';

/// Full-screen overlay shown when an alarm fires.
///
/// Follows the same pattern as _TimerAlertOverlay in hub_shell.dart:
/// - Isolated ConsumerWidget so rebuilds are scoped to this overlay
/// - Uses addPostFrameCallback to wake from idle without setState during build
/// - GestureDetector tap anywhere = snooze, explicit Dismiss button = dismiss
class AlarmAlertOverlay extends ConsumerWidget {
  final VoidCallback onWake;

  const AlarmAlertOverlay({super.key, required this.onWake});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alarmService = ref.watch(alarmServiceProvider);
    final firedAlarm = alarmService.firedAlarm;
    if (firedAlarm == null) return const SizedBox.shrink();

    // Wake from idle when an alarm fires — deferred to avoid
    // notifyListeners() during build.
    WidgetsBinding.instance.addPostFrameCallback((_) => onWake());

    final sunriseController = ref.watch(sunriseControllerProvider);
    final sunriseActive = sunriseController.active;
    final bgColor = sunriseActive ? sunriseController.currentColor : Colors.black;
    // The sunrise ends on a pale gold that white text can't be read against.
    final ink = sunriseActive ? SunriseController.inkOn(bgColor) : Colors.white;

    return GestureDetector(
      // Tap anywhere to snooze
      onTap: alarmService.snooze,
      child: Container(
        color: bgColor.withValues(alpha: 0.95),
        child: Stack(
          children: [
            // Main content — centered time and label
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Current time (large)
                  _CurrentTimeDisplay(color: ink),
                  const SizedBox(height: HearthSpacing.x4),
                  // Alarm icon
                  Icon(Icons.alarm,
                      size: HearthIcon.xl,
                      color: sunriseActive ? ink : const Color(0xFF646CFF)),
                  const SizedBox(height: HearthSpacing.x3),
                  // Alarm label
                  if (firedAlarm.label.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: HearthSpacing.x6),
                      child: Text(
                        firedAlarm.label,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: HearthFont.headline,
                          fontWeight: FontWeight.w300,
                          color: ink.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // Bottom controls
            Positioned(
              left: 0,
              right: 0,
              bottom: HearthSpacing.x12,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Dismiss button (explicit tap target)
                  SizedBox(
                    height: HearthSpacing.x16,
                    width: 200,
                    child: Material(
                      color: ink.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(30),
                      child: InkWell(
                        onTap: alarmService.dismiss,
                        borderRadius: BorderRadius.circular(30),
                        child: Center(
                          child: Text(
                            'Dismiss',
                            style: TextStyle(
                              fontSize: HearthFont.bodyLg,
                              fontWeight: FontWeight.w500,
                              color: ink,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: HearthSpacing.x4),
                  // Snooze hint
                  Text(
                    'Tap anywhere to snooze',
                    style: TextStyle(
                      fontSize: HearthFont.label,
                      color: ink.withValues(alpha: sunriseActive ? 0.7 : 0.4),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Displays the current time, updating every second.
///
/// Isolated in its own widget so 1-second ticks only rebuild this text,
/// not the entire overlay.
class _CurrentTimeDisplay extends StatefulWidget {
  final Color color;

  const _CurrentTimeDisplay({required this.color});

  @override
  State<_CurrentTimeDisplay> createState() => _CurrentTimeDisplayState();
}

class _CurrentTimeDisplayState extends State<_CurrentTimeDisplay> {
  late Timer _ticker;
  late DateTime _now;

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() => _now = DateTime.now()),
    );
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hour = _now.hour.toString().padLeft(2, '0');
    final minute = _now.minute.toString().padLeft(2, '0');
    return Text(
      '$hour:$minute',
      style: TextStyle(
        fontSize: HearthFont.hero, // was 72; snapped to hero=64 (12.5% delta)
        fontWeight: FontWeight.w200,
        color: widget.color,
      ),
    );
  }
}
