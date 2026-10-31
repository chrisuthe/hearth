# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is Hearth?

Hearth is an open-source Flutter smart home kiosk that replaces a Google Nest Hub. It runs on a Raspberry Pi 5 with an 11" AMOLED display via flutter-pi, with a Windows desktop build for development. An Android APK target for kiosk tablets is experimental (see `docs/specs/2026-10-13-android-apk-requirements.md`). It integrates Immich photo memories, Home Assistant controls, Music Assistant playback, and Frigate camera streams.

## Build & Development Commands

```bash
flutter pub get          # install dependencies
flutter analyze          # lint (uses flutter_lints + 3 custom rules)
flutter test             # run all tests
flutter test test/services/display_mode_service_test.dart  # run a single test
flutter test test/portrait   # every surface at landscape + portrait canvases
flutter run -d windows   # run on Windows (dev)
flutter run -d linux     # run on Linux desktop
git submodule update --init  # Android only: the Ava fork and SendspinDroid
flutter build apk --debug  # experimental Android target (needs JDK 17 + Android SDK)
```

For Raspberry Pi deployment, the app runs via flutter-pi (not `flutter run`). On Pi, swap `media_kit` for `flutterpi_gstreamer_video_player` (same video_player API, GStreamer instead of libmpv).

**Android is experimental.** `android/` builds an APK that launches to Home and runs immersive fullscreen, but WiFi management is inert there. Notification, timer and alarm sounds go through `SoundsChannel.kt` (`com.hearth/sounds`) rather than `gst-launch-1.0`: tones on the media volume, alarm tones on the alarm volume. Webview modules render on the system WebView through `flutter_inappwebview` (`AndroidWebviewSession`), checked on the tablet on 2026-10-14, debug and release. Capture runs through MediaProjection, with one consent grant per session (`ScreenCaptureService`); screenshots and recordings, in both orientations and over a playing cast, were checked on the tablet on 2026-10-14. It updates itself from the release `hearth-android-*.apk` through `lib/services/app_updater.dart` and a `PackageInstaller` session, with Android's prompt confirming each install. CI builds it with `scripts/build-android-apk.sh` wherever it builds the Pi bundle (release tags, manual runs, the weekly canary) but not on pull requests. Android takes the `media_kit` path. It can launch other installed apps from tiles chosen in the Apps plugin (`hearth.apps`): split opens the app `LAUNCH_ADJACENT` so Hearth stays top/left, and `AppSessionService` keeps Hearth alive and draws a floating Hearth button over a full-screen app while Hearth is off screen; split and the timer bringing Hearth forward passed on the T901 on 2026-10-17, picture-in-picture is unverified (`docs/specs/2026-10-17-android-app-launcher-design.md`). `docs/specs/2026-10-13-android-apk-requirements.md` is the per-subsystem status and the follow-up list — update it when an Android gap is closed.

**The Android voice satellite is built in and has passed one hardware pass on the tablet.** `HearthAudioService` (`android/app/src/main/kotlin/com/hearth/hearth/voice/`) runs our Ava fork's ESPHome device code, pinned as the `android/third_party/ava` submodule and compiled by the Hearth-owned Gradle scripts under `android/ava/`. Dart drives it through `VoiceSatelliteBridge` over `com.hearth/voice`; the satellite persists nothing, and every setting lives in `HubConfig` (`voice*` fields). A debug build ran on the Apolosign on 2026-10-14: discovery, the four states, mute, announce and the wake word at distance all work; the release (R8) build started and connected to Home Assistant there on 2026-10-14, after a keep rule for the ESPHome protobuf fields, but has not had a spoken exchange. `AudioCoordinator` (native and Dart) lowers Hearth's media_kit playback while the satellite is active, driven by Ava's own duck calls; it ducked a cast on the tablet once, by ear. Voice timers from Home Assistant show in `TimerService` and ring once, through Ava's own ring, which local timers borrow via `startTimerRing`; checked on the tablet on 2026-10-14, timers set from HA rather than spoken. Design: `docs/specs/2026-10-13-android-native-voice-satellite-design.md`.

**Sendspin on Android plays through SendspinDroid's native engine, hosted by the same `HearthAudioService`.** The service runs while voice or Sendspin is wanted, with the microphone foreground type only for voice. `sendspinServiceProvider` builds `AndroidSendspinService`, which drives `com.hearth/sendspin` and never constructs the Dart client, ALSA sink, FLAC FFI or `bonsoir`; the system volume slider uses `STREAM_MUSIC` through the same channel. Only the pairing secrets persist natively (`filesDir/sendspin/`); everything else is `HubConfig`. It passed a first hardware pass on the Apolosign on 2026-10-14, debug and release builds (discovery by Music Assistant, playback, volume both ways, each feature toggled under the other); group sync with the Pi and pairing by token were not run. A server URL is not supported yet. Design and status: `docs/specs/2026-10-14-android-sendspin-design.md`.

## Architecture

### Visual Layer Model (HubShell)

The app has a permanent layered stack, NOT traditional screen navigation:

1. **Photo background** (always visible) — Immich memory carousel, continuously rotating
2. **Active screens** (fade in on touch) — horizontal PageView with dark scrim over photos
3. **Ambient overlays** (fade in when idle) — clock, weather, memory label
4. **Edge-swipe zones + menu overlays** — invisible top/bottom strips; Menu 1 / Menu 2 slide in from their assigned edge
5. **Full-screen overlays** (topmost, in this stacking order) — notification deck, camera feed, alarm alert, DLNA cast, Plex cast, Live TV

The active/ambient layers crossfade via a single `AnimationController`. The app starts idle (ambient visible) and wakes on touch.

Every overlay in layer 5 takes an `onWake` callback and calls it from a post-frame callback, so anything arriving (a cast, an alarm, a notification) both wakes the kiosk and holds off the idle return. Each renders `SizedBox.shrink()` when idle, and each is its own `ConsumerWidget` so high-frequency ticks don't rebuild HubShell.

**Screen order in PageView:** Dynamic — modules with negative `defaultOrder` appear left of Home, positive right. Settings is always last. Default: `Media(-10) ← AlarmClock(-5) ← Home → Calendar(5) → Lists(7) → Controls(10) → LiveTv(15) → Cameras(20) → Protect(25) → Mealie(30) → Settings`

Placement is per-module and multi-valued: `config.modulePlacements` maps a module ID to any of `swipe`, `menu1`, `menu2`, so a module can sit in the swipe row, an edge menu, or both. `swipeModulesProvider` filters to `swipe` and sorts by `config.moduleOrder` when the user has customized it, falling back to `defaultOrder`.

Home is the default page (index 1).

### State Management

All state is Riverpod. Provider types in use:
- `StateNotifierProvider` — config persistence (`HubConfigNotifier`)
- `ChangeNotifierProvider` — idle timer (`IdleController`)
- `StreamProvider` — display mode, HA entity updates, Plex/Live TV player state
- `Provider` — service singletons (HA, Immich, Frigate, Music, Plex, DLNA, Sendspin, MQTT, LocalAPI) and derived lists (`allModulesProvider`, `visiblePluginsProvider`)

### Service Startup

**Most services are not started in an ordered chain.** HA, Music Assistant, Immich, Frigate, and DisplayMode are *self-initializing providers*: they watch their own config fields and connect on their own. When settings change, Riverpod disposes the old instance and constructs a new one that reconnects — so there's no reconnect plumbing to write, and no init call to add.

What `main.dart` actually sequences, in order:

1. **Video player registration** — `media_kit` on desktop, GStreamer on Pi
2. **CaptureService** — built *before* the container so its provider can be overridden (its directory resolves asynchronously)
3. **HubConfig** loads from disk — must complete before anything else reads config
4. **On-screen keyboard control** — installed before any UI mounts, so the first `TextField` focus can surface it
5. **Timezone** — applied before anything reads the clock (Linux only; no-op elsewhere)
6. **LocalApiServer** — starts on port 8090; reads config per-request, so it never restarts on settings change
7. **Eager reads** — Sendspin, voice ducker, DLNA, Plex, MQTT. These are self-initializing too, but need a read at boot to *start advertising* (mDNS / SSDP / GDM / MQTT discovery) rather than waiting for a widget to watch them
8. **AlarmService** — awaited `load()` so persisted alarms and the fire-check ticker are live immediately

The dependency that does exist: **FrigateService** listens to HA events, and **DisplayModeService** can watch an HA entity for night mode. Music Assistant connects directly and does *not* depend on HA.

Keep in mind, all the integration targets (Home assistant, music assistant, immich, frigate, mealie) are open source and we can pull and compare the server/source to verify assumptions: nothing should be guessed at. The same applies to Plex — the Companion/GDM and Live TV paths were built against observed PMS behavior, and the specs in `docs/specs/` record what was verified vs. assumed.

### Configuration

No backend or database. Config is a single `hub_config.json` in the OS app-support directory, loaded/saved via `HubConfigNotifier`. All settings persist immediately on change (no save button). The `HubConfig` class uses `copyWith` for immutable updates.

Night mode has four mutually exclusive sources: `none`, `clock`, `ha_entity`, `api`. Only one is active — no fallback chain.

The look is two fields: `theme` (`classic | bright | warm | memories | catppuccin_latte | catppuccin_frappe | catppuccin_macchiato | catppuccin_mocha | tokyonight_night | tokyonight_storm | tokyonight_moon | tokyonight_day`) and `screenBackground` (`solid | blurred`, a blurred copy of the current photo behind each screen). Their Theme and Background controls are in the Display settings.

### Display Canvas & Orientation

Screens are tuned for a 1184x864 landscape canvas — the 11" panel's 2368x1728 at 2x. `kWindowWidth`/`kWindowHeight` in `main.dart` record that reference and are read by nothing: the canvas is whatever `MediaQuery` reports (flutter-pi derives it from the panel mode), divided by `uiScale` in `HearthScaleScope`.

`config.displayOrientation` (`auto | landscape | portrait | landscapeFlipped | portraitFlipped`, see `lib/config/display_orientation.dart`) turns the screen:

- **Pi** — `hearth.service` execs `/usr/local/bin/hearth-launch` (`scripts/hearth-launch.sh`), which reads the value from `hub_config.json` and passes flutter-pi `--rotation`. It is fixed for the life of the process, so a change needs `systemctl restart hearth.service`; the Display plugin offers that when the setting differs from `HEARTH_APPLIED_ROTATION`, the env var the launcher exports. The degree table lives twice (shell + Dart) and `test/scripts/pi_scripts_test.dart` holds them together.
- **Android** — `androidOrientationProvider` calls `setPreferredOrientations`, live.
- **Desktop** — stored, no effect.

Layouts must hold at 864x1184 and 800x1280 as well as 1184x864. Branch on `MediaQuery`/`LayoutBuilder`, never on `displayOrientation`, so a resized desktop window behaves like a rotated panel. `test/portrait/` pumps every surface at all three sizes via `testLayouts` — add a new screen there.

### Module System

Optional screens implement `HearthModule` (in `lib/modules/hearth_module.dart`). Each module provides an `id`, `name`, `icon`, `defaultOrder`, `isConfigured()`, `buildScreen()`, and `buildSettingsSection()`. Modules live in `lib/modules/<name>/` with their screen, service, and data models. The registry is a static list in `lib/modules/module_registry.dart`. HubShell builds the PageView dynamically from enabled modules (configured in Settings).

Current static modules (`_staticModules`): Alarm Clock, Media (music), Calendar (HA + ICS, read-only), Lists (HA to-do), Controls (HA entities), Cameras (Frigate), Protect (UniFi Protect), Recipes (Mealie), Live TV (Plex DVR).

**Webview modules are dynamic** — `modulesForConfig()` synthesizes one `WebviewModule` per entry in `config.webviews`, so the module list is a function of config, not a fixed array. Use `modulesForConfig(config)` from non-Riverpod code (e.g. the web portal's Screens & Order render) and `allModulesProvider` from widgets.

### Plugin System (settings)

Settings are **plugins** (`lib/plugins/`), a separate registry from modules. A plugin renders itself twice from one definition — `buildSettingsWidget(ref)` for the on-device sidebar and `buildSettingsHtml(ctx)` for the `:8090` portal — which is what keeps the two surfaces at parity. Plugins may also register HTTP routes via `registerHttpRoutes(PluginRouter)`, served under `/api/plugin/<id>/*`.

Registry is `_firstPartyPlugins` in `lib/plugins/plugin_registry.dart`, sorted by `(category, order)`. `isVisible(config)` gates conditional entries (e.g. Capture only appears when `captureToolsEnabled`); sidebar surfaces watch `visiblePluginsProvider`, not `allPluginsProvider`.

**Modules ≠ plugins.** A module is a *screen*; a plugin is a *settings panel*. Some features have both (Calendar, Lists, Frigate, Mealie, Protect), some only a plugin (Weather, Network, System), and Live TV is a module with no plugin of its own — it's configured by the Plex Cast plugin's pairing.

**People** (`hearth.people`) is a plugin with no module: the household registry in `config.people` (`lib/config/person.dart`), each person optionally linked to an HA `person.*` for an avatar and presence (`lib/services/people.dart`). Lists and Calendar reference people by `personId`, never by name; change the registry through `HubConfig.withPeople` so a removed person's id is cleared everywhere. Design: `docs/specs/2026-10-15-people-design.md`.

Plugin routes are **not** auto-gated by `isVisible` — a hidden plugin's routes still resolve, so each handler must enforce its own gate (see `CapturePlugin._gated`).

## Git

The default branch is `main`. All PRs target `main`.

## Conventions

- Linting enforces `prefer_const_constructors`, `prefer_const_declarations`, and `avoid_print` (use `debugPrint` instead)
- Tests use `flutter_test` + `mockito`. WebSocket tests use custom `FakeWebSocketChannel` classes
- UI colors come from `HearthColors` roles (`context.hearthColors`, `lib/app/theme/hearth_colors.dart`), never literals. `test/app/theme/theme_literal_guard_test.dart` enforces this for the files it lists; out-of-scope surfaces mark literals `// theme-exempt: <reason>`
- Themes are `HearthThemeId` + `HearthColors.forTheme`. `test/app/theme/contrast_test.dart` is binding: a palette change that fails it is wrong, not the test. New screens draw their backdrop with `ThemedBackground`
- Classic keeps a true-black canvas for AMOLED power savings; Home and the Media player while playing stay on Classic (`ClassicThemeScope`)
- New palettes go in `lib/app/theme/palettes/`, need a `notices.json` entry, and must pass `contrast_test.dart`

## Dependency maintenance

Renovate runs weekly on Gitea Actions (`.gitea/workflows/renovate.yml`, config
in `renovate.json`). Packages and Actions automerge on green CI. The Flutter
pin, `dart`, `flutterpi_tool`, and the three fork tags never automerge.
Neither do Android Gradle deps or the Gradle wrapper: PR CI does not build the
APK, so run `flutter build apk --debug` before merging one. The Kotlin plugins
and libraries are grouped into one `kotlin` PR so they never split versions.

**The Flutter pin is not independent.** `flutterpi_tool` must ship arm64 engine
support before the Pi can build a given Flutter version, and that has lagged by
up to nine weeks. Always bump `flutterpi_tool` first; its changelog states which
Flutter versions it unlocked. All four `flutter-version` pins (GitHub + Gitea ×
desktop + Pi) must move together — a split makes Renovate emit competing update
branches. `dart` (the `environment: sdk:` constraint) is similarly pinned because
the desktop workflow uses `channel: stable` and would stay green on a raised SDK
floor while the Pi's pinned older Flutter breaks.

**Flutter bumps need a hardware test, not just green CI.** The 3.44.9 engine
segfaulted flutter-pi a few seconds into a **1080p h264 direct-play** stream on
the Pi. Bisected on hardware: 3.44.9 crashed 2/2 on the same file; 3.41.6 and
3.38.0 played it fine; 720p was unaffected on all three. The crash is silent — no
GStreamer error, no Dart exception — so it will not show up in CI, only on a
device. 3.47.6 was accepted after it booted on the Pi and direct-played a
generated 1080p h264 clip for 60s. That clip also played on 3.44.9, so the
original crash was not reproduced and is **not proven fixed**. Flutter is now
pinned at 3.47.7, which passed the same check on the same kind of clip (see
`docs/specs/2026-10-13-v1.21.0-release-readiness.md`). Before accepting any
Flutter bump, cast a 1080p direct-play title on a real Pi.

**`flutterpi_tool` is temporarily installed from an unreleased upstream commit.**
The latest pub.dev release (0.12.0) does not compile against Flutter 3.47, so
both Pi workflows pin upstream's 3.47 commit by full SHA. A `# Renovate anchor:`
comment beside it keeps Renovate watching for the next release. Move back to a
pub.dev version when one ships with 3.47 support — tracked in issue #226.

**The Ava fork is pinned as a git submodule, which Renovate does not track.**
`android/third_party/ava` records a commit (tag `v0.6.2-hearth.1`), and Renovate's
`git-submodules` manager is off and follows branches, not tags. Bump it by hand:
check out the new tag inside the submodule, commit the pointer, and run
`flutter build apk --debug`. The fork's dependency versions are read from its
own `gradle/libs.versions.toml`, so they move with the pin and Renovate sees
none of them. `android/ava/satellite/build.gradle.kts` mirrors the fork's
dependency list by hand and needs the same edit when the fork adds one.
The R8 keep rule for the fork's protobuf-lite messages
(`android/ava/esphomeproto/src/main/resources/META-INF/proguard/esphomeproto.pro`)
names their package, `com.example.esphomeproto`; a proto in another package
needs adding there, or the release APK crashes when Home Assistant connects.

**SendspinDroid is pinned the same way.** `android/third_party/sendspindroid`
records commit `a135c27c` (tag `v2.0.0`). Pin release tags: a `v*` tag in
SendspinDroid publishes an app release, so tags mark tested points.
Renovate cannot see the pin or anything behind it.
SendspinDroid has no version catalog, so `android/sendspin/shared/build.gradle.kts`
and `android/sendspin/player/build.gradle.kts` copy the dependency versions and
exclusions from its `shared/` and `player/` scripts by hand. Bump it by hand:
check out the new tag inside the submodule, diff those two upstream scripts
since the old pin, carry any change across, commit the pointer, and run both
`flutter build apk --debug` and `scripts/build-android-apk.sh` (R8 reads the
player's `consumer-rules.pro` from the submodule). Also diff upstream's
`app/.../playback/PlaybackService.kt`: `SendspinPlayer` is ported from it, and
fixes made there (not in `:player`/`:shared`) never reach Hearth through the
pin. It is ours, not a fork, so the drift check does not cover it.

Two checks cover what Renovate cannot see:
- `.gitea/workflows/upstream-drift.yml` — weekly, compares each fork's
  `UPSTREAM_PIN` against its upstream HEAD and opens a tracking issue. Covers
  flutter-pi, the GStreamer plugin and Ava.
- `.github/workflows/build-pi-image.yml` — weekly scheduled run, cross-compiles
  for arm64 and builds the Android APK. Desktop CI does neither.

Design rationale: `docs/specs/2026-08-12-dependency-maintenance-process-design.md`

**Third-party notices.** Anything shipped that is not a Dart package needs an
entry in `assets/licenses/notices.json`: a bundled asset, a fork, a submodule,
a module under `android/ava/`, `android/sendspin/` or `native/`, an Android library. Then run
`dart run tool/gen_third_party_notices.dart` to regenerate
`THIRD_PARTY_NOTICES.md`. `test/services/third_party_notices_test.dart` catches
all of these except new Android libraries, which need a manual check of
`:app:dependencies`. The satellite's wake-word models are an allowlist in
`android/ava/satellite/build.gradle.kts`; never ship a model without a licence.
Design: `docs/specs/2026-10-14-third-party-notices-design.md`
