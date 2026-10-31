import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'tokens/tokens.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/hub_config.dart';
import 'current_screen_provider.dart';
import 'idle_controller.dart';
import 'page_visibility.dart';
import 'page_indicator.dart';
import 'screen_navigator.dart';
import '../models/photo_memory.dart';
import '../modules/hearth_module.dart';
import '../modules/module_registry.dart';
import '../screens/ambient/ambient_screen.dart';
import '../screens/timer/timer_screen.dart';
import '../services/timer_service.dart';
import '../services/notification_service.dart';
import '../widgets/notification_deck_overlay.dart';
import '../screens/home/home_screen.dart';
import '../screens/settings/settings_screen.dart';
import '../modules/alarm_clock/alarm_alert_overlay.dart';
import '../modules/cameras/camera_feed_overlay.dart';
import '../modules/alarm_clock/alarm_service.dart';
import '../modules/alarm_clock/sunrise_controller.dart';
import '../modules/lists/lists_providers.dart';
import '../modules/webview/webview_session_pool.dart';
import '../modules/android_app/android_app_launch_card.dart';
import '../modules/android_app/android_app_module.dart';
import '../services/dlna/dlna_cast_overlay.dart';
import '../services/plex/plex_cast_overlay.dart';
import '../modules/livetv/live_tv_overlay.dart';
import '../services/sendspin/android_sendspin_service.dart';
import '../services/sendspin/sendspin_service.dart';
import '../services/toast_service.dart';
import '../widgets/toast_overlay.dart';
import 'theme/hearth_colors.dart';
import '../widgets/voice_pill.dart';
import '../services/voice_assistant_service.dart';
import '../widgets/themed_background.dart';

/// The main shell that manages the layered navigation model.
///
/// Two visual layers, bottom to top:
/// 1. Photo background — always visible, continuously rotates Immich memories.
/// 2. Active layer — PageView with screens over the photo background.
///    Home screen is transparent; other screens use a dark scrim.
///
/// Screen order (horizontal swipe):
///   Media ← Home → Controls → Cameras → Settings
class HubShell extends ConsumerStatefulWidget {
  const HubShell({super.key});

  @override
  ConsumerState<HubShell> createState() => _HubShellState();
}

class _HubShellState extends ConsumerState<HubShell> {
  PageController? _pageController;

  int _homeIndex = 0;
  int _pageCount = 0;
  /// Ordered screen ids matching the PageView pages, kept in sync on each
  /// build so the page listener can map an index to a screen id for
  /// [currentScreenProvider]. Layout: leftModules · home · rightModules · settings.
  List<String> _screenIds = const [];
  late final FocusNode _focusNode;
  final _ambientKey = GlobalKey<AmbientScreenState>();
  PhotoMemory? _currentMemory;
  int _currentPage = 0;
  bool _menu1Open = false;
  bool _menu2Open = false;
  StreamSubscription<String>? _screenRequests;
  static const double _edgeZoneHeight = 80;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _screenRequests =
        ref.read(screenNavigatorProvider).requests.listen(_showRequestedScreen);
  }

  @override
  void dispose() {
    _screenRequests?.cancel();
    _focusNode.dispose();
    _pageController?.dispose();
    super.dispose();
  }

  void _onUserActivity() {
    ref.read(idleControllerProvider).onUserActivity();
    // Resume any paused webviews.
    ref.read(webviewSessionPoolProvider).resumeAll();
  }

  /// Shows screen [id] for [ScreenNavigator] (the local API and MQTT). It
  /// counts as activity, so the idle return to Home restarts from now; menus
  /// close and pushed routes pop so the page is what's on screen.
  void _showRequestedScreen(String id) {
    final index = _screenIds.indexOf(id);
    if (!mounted || index < 0) return;
    _onUserActivity();
    setState(() {
      _menu1Open = false;
      _menu2Open = false;
    });
    Navigator.of(context).popUntil((route) => route.isFirst);
    _pageController?.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  /// Reflect the active page into [currentScreenProvider] so services (MQTT)
  /// can observe it. Safe to call outside build.
  void _publishCurrentScreen(int page) {
    if (page < 0 || page >= _screenIds.length) return;
    final info = CurrentScreen(id: _screenIds[page], index: page);
    final notifier = ref.read(currentScreenProvider.notifier);
    if (notifier.state != info) notifier.state = info;
    ref.read(basePageProvider.notifier).state = info.id;
  }

  /// Pushes [m]'s screen over the shell, named by its id so the page reads
  /// `route:<id>` while it is open (see [PageRouteObserver]).
  void _openMenuModule(HearthModule m) {
    if (m is AndroidAppModule) {
      launchAndroidApp(ref, m.config);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        settings: RouteSettings(name: m.id),
        builder: (_) => _MenuScreenWrapper(
          title: m.name,
          child: m.buildScreen(isActive: true),
        ),
      ),
    );
  }

  String? _edgeFor(String action) {
    final config = ref.read(hubConfigProvider);
    if (config.topSwipeAction == action) return 'top';
    if (config.bottomSwipeAction == action) return 'bottom';
    return null;
  }

  Widget _configEdgeSwipeZone({
    required AlignmentGeometry alignment,
    required String action,
    required bool swipeDown,
  }) {
    // Only intercepts deliberate vertical drags meeting a velocity threshold;
    // single taps and slow horizontal motion pass through to the webview (or
    // whatever's underneath). Omitting onVerticalDragUpdate prevents the
    // detector from claiming ownership of every touch in the edge zone.
    return Align(
      alignment: alignment,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragEnd: (details) {
          final v = details.primaryVelocity ?? 0;
          if ((swipeDown && v > 200) || (!swipeDown && v < -200)) {
            _onUserActivity();
            _dispatchSwipeAction(action);
          }
        },
        child: const SizedBox(
          width: double.infinity,
          height: _edgeZoneHeight,
        ),
      ),
    );
  }

  void _dispatchSwipeAction(String action) {
    switch (action) {
      case 'menu1':
        setState(() { _menu1Open = true; _menu2Open = false; });
      case 'menu2':
        setState(() { _menu2Open = true; _menu1Open = false; });
      case 'settings':
        _pageController!.animateToPage(
          _pageCount - 1,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      case 'nextScreen':
        final current = _pageController!.page?.round() ?? _homeIndex;
        if (current < _pageCount - 1) {
          _pageController!.animateToPage(current + 1,
            duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
        }
      case 'previousScreen':
        final current = _pageController!.page?.round() ?? _homeIndex;
        if (current > 0) {
          _pageController!.animateToPage(current - 1,
            duration: const Duration(milliseconds: 300), curve: Curves.easeInOut);
        }
    }
  }

  /// Handles arrow key navigation for desktop testing.
  /// Left/Right move between screens, Up = Home, Down = Settings.
  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    _onUserActivity();

    final currentPage = _pageController!.page?.round() ?? _homeIndex;

    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      if (currentPage > 0) {
        _pageController!.animateToPage(
          currentPage - 1,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
    } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      if (currentPage < _pageCount - 1) {
        _pageController!.animateToPage(
          currentPage + 1,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _pageController!.animateToPage(
        _pageCount - 1,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
        event.logicalKey == LogicalKeyboardKey.home) {
      _pageController!.animateToPage(
        _homeIndex,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  Widget _buildMenu1({required bool fromTop}) {
    return _MenuTray(
      fromTop: fromTop,
      onDismiss: () => setState(() => _menu1Open = false),
      // Wrap, not Row: a portrait panel fits seven tiles across and a tray
      // can hold more than that.
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: HearthSpacing.x3,
        runSpacing: HearthSpacing.x3,
        children: [
          _Menu1TimerAction(
            onTap: () {
              setState(() => _menu1Open = false);
              Navigator.of(context).push(MaterialPageRoute(
                settings: const RouteSettings(name: 'timer'),
                builder: (_) => const TimerScreen(),
              ));
            },
          ),
          _QuickAction(
            icon: Icons.settings,
            label: 'Settings',
            onTap: () {
              setState(() => _menu1Open = false);
              _pageController!.animateToPage(
                _pageCount - 1,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
              );
            },
          ),
          ...menuModules(ref, 'menu1').map((m) => _QuickAction(
            icon: m.icon,
            label: m.name,
            onTap: () {
              setState(() => _menu1Open = false);
              _openMenuModule(m);
            },
          )),
        ],
      ),
    );
  }

  Widget _buildMenu2({required bool fromTop}) {
    final menu2Items = menuModules(ref, 'menu2');
    return _MenuTray(
      fromTop: fromTop,
      onDismiss: () => setState(() => _menu2Open = false),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Volume', style: TextStyle(fontSize: HearthFont.caption, color: context.hearthColors.textMuted)),
          const SizedBox(height: HearthSpacing.x1),
          const _SystemVolumeSlider(),
          if (menu2Items.isNotEmpty) ...[
            const SizedBox(height: HearthSpacing.x3),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: HearthSpacing.x3,
              runSpacing: HearthSpacing.x3,
              children: menu2Items.map((m) => _QuickAction(
                icon: m.icon,
                label: m.name,
                onTap: () {
                  setState(() => _menu2Open = false);
                  _openMenuModule(m);
                },
              )).toList(),
            ),
          ],
        ],
      ),
    );
  }

  /// The chore glance's tap: the Lists page, on the chore chart.
  VoidCallback? _choresTap(List<dynamic> leftModules,
      List<dynamic> rightModules, int homeIndex) {
    final tap = _moduleTap('lists', leftModules, rightModules, homeIndex);
    if (tap == null) return null;
    return () {
      ref.read(listsViewProvider.notifier).state = ListsView.chores;
      tap();
    };
  }

  /// Jumps to module [id]'s page; null when it is not in the swipe row.
  VoidCallback? _moduleTap(String id, List<dynamic> leftModules,
      List<dynamic> rightModules, int homeIndex) {
    final left = leftModules.indexWhere((m) => m.id == id);
    final right = rightModules.indexWhere((m) => m.id == id);
    if (left < 0 && right < 0) return null;
    final index = left >= 0 ? left : homeIndex + 1 + right;
    return () {
      _onUserActivity();
      _pageController!.animateToPage(
        index,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    };
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(hubConfigProvider);
    final idleController = ref.read(idleControllerProvider);

    final layout = ref.watch(shellLayoutProvider);
    final leftModules = layout.left;
    final rightModules = layout.right;
    final homeIndex = layout.homeIndex;

    // Mirror the page order as ids so the page listener can resolve an index
    // to a screen id for currentScreenProvider (consumed by MqttService).
    _screenIds = [for (final s in layout.screens) s.id];
    _pageCount = _screenIds.length;

    // Recreate PageController when the module layout changes.
    if (_pageController == null || _homeIndex != homeIndex) {
      _homeIndex = homeIndex;
      _pageController?.dispose();
      _pageController = PageController(initialPage: homeIndex);
      _currentPage = homeIndex;
      _pageController!.addListener(() {
        final page = _pageController!.page?.round() ?? _homeIndex;
        if (page != _currentPage) {
          setState(() => _currentPage = page);
          _publishCurrentScreen(page);
        }
      });
      // Seed the provider with the initial (Home) page once mounted; can't
      // mutate a provider during build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _publishCurrentScreen(_homeIndex);
      });
      idleController.onTimeout = () {
        // Pause warm webviews — they keep memory but stop producing frames.
        ref.read(webviewSessionPoolProvider).pauseAll();
        // Pop any pushed routes (e.g. TimerScreen) unless a notification (a
        // fired-timer card or any deck card) or an alarm is active — those
        // overlays should stay visible.
        final notificationService = ref.read(notificationServiceProvider);
        final alarmService = ref.read(alarmServiceProvider);
        if (!notificationService.hasActive && alarmService.firedAlarm == null) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
        _pageController?.animateToPage(
          _homeIndex,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      };
    }

    final pages = <Widget>[
      ...leftModules.map((m) => m.buildScreen(
          isActive: _currentPage == leftModules.indexOf(m))),
      HomeScreen(
        dateLabel: _currentMemory?.dateLabel,
        onSkipPhoto: () => _ambientKey.currentState?.skipForward(),
        onSkipPhotoBack: () => _ambientKey.currentState?.skipBack(),
        onChevronTap: () => _onUserActivity(),
        onNowPlayingTap: () {
          // Navigate to Media screen (first left module)
          final mediaIndex = leftModules.indexWhere((m) => m.id == 'media');
          if (mediaIndex >= 0) {
            _onUserActivity();
            _pageController!.animateToPage(
              mediaIndex,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
            );
          }
        },
        onCalendarTap:
            _moduleTap('calendar', leftModules, rightModules, homeIndex),
        onListsTap: _choresTap(leftModules, rightModules, homeIndex),
      ),
      ...rightModules.map((m) => m.buildScreen(
          isActive: _currentPage == homeIndex + 1 + rightModules.indexOf(m))),
      const SettingsScreen(),
    ];

    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: (_) => _onUserActivity(),
        child: Stack(
          children: [
            // Layer 1: Photo background — always visible behind everything.
            // The AmbientScreen handles its own photo rotation and caching.
            AmbientScreen(
              key: _ambientKey,
              onMemoryChanged: (memory) {
                setState(() => _currentMemory = memory);
              },
            ),

            // Sunrise gradient — overlays the photo background when an alarm
            // sunrise is active. Fades from black through dawn colors.
            _SunriseGradientLayer(),

            // Layer 2: Active screens — PageView over the photo background.
            PageView(
              controller: _pageController,
              physics: const BouncingScrollPhysics(),
              children: pages,
            ),

            // Page position indicator — dot row at the bottom center.
            // Positioned above the bottom edge-swipe zone so it does
            // not interfere with vertical drag gestures.
            Positioned(
              bottom: _edgeZoneHeight + 8,
              left: 0,
              right: 0,
              child: Center(
                child: PageIndicator(
                  pageCount: _pageCount,
                  currentPage: _currentPage,
                ),
              ),
            ),

            // Toast overlay — brief feedback messages from any service.
            const ToastOverlay(),

            // Voice pill — floating feedback overlay for voice assistant.
            const VoicePillOverlay(),

            // Mic mute toggle — always visible, top-left corner.
            // Reflects the satellite's actual HA Mute switch state (so mutes
            // from HA automations / the device button show here too), falling
            // back to the locally-stored intent until HA's state is known.
            // The in-app satellite never reports an HA state, so it shows
            // `micMuted`, which the bridge keeps in step with HA.
            Positioned(
              top: HearthSpacing.x6,
              left: HearthSpacing.x6,
              child: Consumer(builder: (context, ref, _) {
                // HA's switch state wins when known; until then fall back to
                // the locally-stored intent.
                final bool muted =
                    switch (ref.watch(voiceMutedProvider).valueOrNull) {
                  final bool haMuted => haMuted,
                  null => ref
                      .watch(hubConfigProvider.select((c) => c.micMuted)),
                };
                return IconButton(
                  icon: Icon(
                    muted ? Icons.mic_off : Icons.mic,
                    color: muted
                        ? context.hearthColors.danger
                        : context.hearthColors.textMuted,
                    size: HearthIcon.lg,
                  ),
                  onPressed: () {
                    final newValue = !muted;
                    // Drive the real mute via HA; keep micMuted as the persisted
                    // local intent / fallback display until HA confirms.
                    ref
                        .read(voiceAssistantServiceProvider)
                        .setSatelliteMuted(newValue);
                    ref.read(hubConfigProvider.notifier).update(
                      (c) => c.copyWith(micMuted: newValue),
                    );
                    ref.read(toastProvider.notifier).show(
                      newValue ? 'Microphone muted' : 'Microphone unmuted',
                      icon: newValue ? Icons.mic_off : Icons.mic,
                    );
                  },
                );
              }),
            ),

            // Edge-swipe zones — invisible strips at top/bottom that
            // dispatch configurable actions on vertical drag.
            _configEdgeSwipeZone(
              alignment: Alignment.topCenter,
              action: config.topSwipeAction,
              swipeDown: true,
            ),
            _configEdgeSwipeZone(
              alignment: Alignment.bottomCenter,
              action: config.bottomSwipeAction,
              swipeDown: false,
            ),

            // Menu overlays — slide in from their assigned edge
            if (_menu1Open) _buildMenu1(fromTop: _edgeFor('menu1') == 'top'),
            if (_menu2Open) _buildMenu2(fromTop: _edgeFor('menu2') == 'top'),

            // Notification deck — bottom-deck cards for every notification
            // source, including fired timers. Isolated in its own
            // ConsumerWidget so 200ms timer ticks only rebuild this overlay,
            // not the entire HubShell. Renders nothing when the deck is empty.
            NotificationDeckOverlay(onWake: _onUserActivity),

            // Camera feed — full-screen live view opened from a notification
            // card. Renders nothing when closed.
            CameraFeedOverlay(onWake: _onUserActivity),

            // Alarm alert — full-screen overlay when an alarm fires.
            AlarmAlertOverlay(onWake: _onUserActivity),

            // DLNA cast — full-screen video overlay when a control point
            // casts a video to the kiosk. Renders nothing when idle.
            DlnaCastOverlay(onWake: _onUserActivity),

            // Plex cast — full-screen video overlay when a Plex app casts a
            // video to the kiosk. Renders nothing when idle.
            PlexCastOverlay(onWake: _onUserActivity),

            // Plex Live TV — full-screen video overlay while a channel is
            // tuning/playing (client-initiated). Renders nothing when idle.
            LiveTvOverlay(onWake: _onUserActivity),
          ],
        ),
      ),
    );
  }
}

/// Sunrise gradient overlay — renders the dawn color ramp above the photo
/// background when a sunrise alarm is active. Isolated in its own
/// ConsumerWidget so 1-second sunrise ticks only rebuild this layer.
class _SunriseGradientLayer extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sunrise = ref.watch(sunriseControllerProvider);
    if (!sunrise.active) return const SizedBox.shrink();
    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          color: sunrise.currentColor.withValues(alpha: sunrise.overlayAlpha),
        ),
      ),
    );
  }
}

/// Timer action button for menu1 — isolated so its ref.watch on
/// timerServiceProvider only rebuilds this widget, not the menu tray
/// or the HubShell.
class _Menu1TimerAction extends ConsumerWidget {
  final VoidCallback onTap;

  const _Menu1TimerAction({required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timerService = ref.watch(timerServiceProvider);
    return _QuickAction(
      icon: Icons.timer,
      label: timerService.hasActiveTimers
          ? timerService.statusLabel
          : 'Timer',
      active: timerService.hasActiveTimers,
      onTap: onTap,
    );
  }
}

/// A single square item in the quick actions tray.
class _QuickAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;

  const _QuickAction({
    required this.icon,
    required this.label,
    this.active = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.hearthColors;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        splashColor: c.inkAt(0.24),
        child: Container(
          width: 88,
          height: 88,
          decoration: BoxDecoration(
            color: active
                ? c.accent.withValues(alpha: 0.2)
                : c.inkAt(0.08),
            borderRadius: BorderRadius.circular(16),
            border: active
                ? Border.all(
                    color: c.accent.withValues(alpha: 0.5))
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 28,
                  color: active ? c.accentText : c.textSecondary),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(fontSize: HearthFont.caption, color: c.textSecondary),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuTray extends StatelessWidget {
  final bool fromTop;
  final VoidCallback onDismiss;
  final Widget child;

  const _MenuTray({
    required this.fromTop,
    required this.onDismiss,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onDismiss,
      child: SizedBox.expand(
        child: Stack(
          children: [
            Positioned(
              top: fromTop ? 0 : null,
              bottom: fromTop ? null : 0,
              left: 0,
              right: 0,
              child: GestureDetector(
                onVerticalDragEnd: (details) {
                  final v = details.primaryVelocity ?? 0;
                  if ((fromTop && v < -200) || (!fromTop && v > 200)) {
                    onDismiss();
                  }
                },
                onTap: () {},
                child: Container(
                  margin: EdgeInsets.only(
                    top: fromTop ? HearthSpacing.x3 : 0,
                    bottom: fromTop ? 0 : HearthSpacing.x3,
                    left: HearthSpacing.x6,
                    right: HearthSpacing.x6,
                  ),
                  padding: const EdgeInsets.all(HearthSpacing.x4),
                  decoration: BoxDecoration(
                    color: context.hearthColors.menu,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (fromTop) ...[
                        child,
                        const SizedBox(height: HearthSpacing.x2),
                        Container(
                          width: HearthSpacing.x10, height: HearthSpacing.x1,
                          decoration: BoxDecoration(
                            color: context.hearthColors.inkAt(0.3),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ] else ...[
                        Container(
                          width: HearthSpacing.x10, height: HearthSpacing.x1,
                          decoration: BoxDecoration(
                            color: context.hearthColors.inkAt(0.3),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(height: HearthSpacing.x2),
                        child,
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// System volume slider synced with Sendspin.
///
/// When Sendspin is active, the slider reflects the Sendspin volume (which
/// the server controls). Slider changes are pushed to both ALSA hardware
/// and reported back to the Sendspin server via client/state.
/// When Sendspin is inactive, the slider controls ALSA directly.
///
/// On Android the device's media volume (`STREAM_MUSIC`) stands in for ALSA,
/// and the native side reports a change to the server itself.
class _SystemVolumeSlider extends ConsumerStatefulWidget {
  const _SystemVolumeSlider();

  @override
  ConsumerState<_SystemVolumeSlider> createState() => _SystemVolumeSliderState();
}

class _SystemVolumeSliderState extends ConsumerState<_SystemVolumeSlider> {
  double _volume = 0.5;
  Timer? _debounce;
  bool _userDragging = false;

  @override
  void initState() {
    super.initState();
    _readVolume();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _readVolume() async {
    final vol = sendspinNative
        ? await AndroidSendspinService.readMediaVolume()
        : await SendspinService.readAlsaVolume();
    if (vol != null && mounted) {
      setState(() => _volume = vol);
    }
  }

  void _onChanged(double value) {
    _userDragging = true;
    setState(() => _volume = value);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 100), () async {
      _userDragging = false;
      if (sendspinNative) {
        await AndroidSendspinService.setMediaVolume(value);
        return;
      }
      // Set ALSA hardware volume (detects correct control name).
      await SendspinService.setAlsaVolume((value * 100).round(), false);
      // If Sendspin is active, report the volume change to the server.
      final sendspin = ref.read(sendspinServiceProvider);
      if (sendspin.state.isActive) {
        sendspin.setVolume(value);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Sync from Sendspin volume when not dragging.
    final ssAsync = ref.watch(sendspinStateProvider);
    final ssState = ssAsync.valueOrNull;
    if (ssState != null && ssState.isActive && !_userDragging) {
      final ssVol = ssState.volume;
      if ((ssVol - _volume).abs() > 0.01) {
        // Schedule to avoid setState during build.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _volume = ssVol);
        });
      }
    }

    final c = context.hearthColors;
    return Row(
      children: [
        Icon(Icons.volume_down, color: c.textMuted, size: HearthIcon.sm),
        Expanded(
          child: Slider(
            value: _volume,
            onChanged: _onChanged,
            activeColor: c.textSecondary,
            inactiveColor: c.inkAt(0.1),
          ),
        ),
        Icon(Icons.volume_up, color: c.textMuted, size: HearthIcon.sm),
      ],
    );
  }
}

/// Wraps a module screen launched from a menu with a close button.
///
/// Module screens are designed for the swipeable PageView and don't include
/// their own navigation chrome. When pushed as a route from a menu, this
/// wrapper adds a back button so the user can return.
class _MenuScreenWrapper extends StatelessWidget {
  final String title;
  final Widget child;

  const _MenuScreenWrapper({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final c = context.hearthColors;
    return ThemedBackground.screen(
      child: Stack(
        children: [
          child,
          Positioned(
            top: HearthSpacing.x3,
            left: HearthSpacing.x3,
            child: IconButton(
              icon: Icon(Icons.close, color: c.textSecondary, size: 28),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }
}
