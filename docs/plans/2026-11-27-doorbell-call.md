# Doorbell Call View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `ring: true` doorbell payload opens a full-screen call view on Android Hearths, with live WebRTC video and audio from go2rtc, a large Talk toggle that sends the mic over a second WebRTC connection, and Hang up. The voice satellite is paused and other playback is muted for the whole view.

**Architecture:** `NotificationService` parses `ring` and emits honoured rings. `DoorbellCallController` (a Riverpod `StateNotifier`, read at boot on Android) owns the lifetime rules and one `DoorbellCallSession` per open view. The session owns the media (an injected `RtcClient`, whose real implementation is flutter_webrtc over go2rtc's WebSocket signalling) and the platform hold (`DoorbellPlatform` over `com.hearth/doorbell`: satellite capture hold, Sendspin mute and keep-screen-on), and always releases the hold in a `finally`. `DoorbellCallOverlay` only renders.

**Tech Stack:** Flutter/Riverpod, `flutter_webrtc` 1.6.3, `web_socket_channel`, Kotlin (HearthAudioService, Ava `VoiceInputImpl`, SendspinDroid engine), `fake_async`/`mockito` tests.

**Spec:** `docs/specs/2026-11-27-doorbell-call-design.md` (issue #315, plus "Decided during planning" at the end, which overrides the issue where they differ).

## Global Constraints

- Android only at runtime. Gate everything on `doorbellCallSupported` (`dart:io` `Platform.isAndroid`, with a `@visibleForTesting` override, like `voiceSatelliteSupported`). On other platforms `ring` changes nothing, not even the dismissed-tag bypass.
- The mic opens only inside `RtcClient.talk`, which only a Talk tap reaches. No pre-warmed `getUserMedia`.
- Satellite pause covers the **whole** view, starts before any doorbell audio plays, and is released on every exit path. It never touches `micMuted`, `setMuted` or the HA mute switch.
- Signalling: `ws://<frigate host>:1984/api/ws?src=<camera>`, go2rtc v1 messages (`webrtc/offer`, `webrtc/answer`, `webrtc/candidate`, `error`). No credentials, no ICE servers.
- WebRTC connect timeout: 5 s (`kDoorbellConnectTimeout`), for both connections.
- View lifetime: Talk never used → payload `timeout`, or 3 min (`kDoorbellQuietTimeout`). Talk used → `kCameraFeedMaxDuration` (5 min) counted from opening.
- Toast copy: `Talk unavailable` (WebRTC or Talk failure), `Microphone permission needed` (mic denied).
- Lint: `prefer_const_constructors`, `prefer_const_declarations`, `avoid_print`. Colours from `context.hearthColors`. Video backdrops may use `Colors.black // theme-exempt: video`, as `camera_feed_overlay.dart` does.
- Commits are written as the user, with no AI attribution or `Co-Authored-By` lines. Messages reference `#315`.
- Toolchain: `export PATH="/c/flutter/bin:$PATH"`. Git network calls need `git -c credential.helper= -c credential.helper=manager …` on this machine.
- Lockfile: the `test_api 0.7.14` and `listen` entries in `pubspec.lock` stay as on `main`. Only the WebRTC packages (`flutter_webrtc`, `dart_webrtc`, `webrtc_interface`, `logger`) are added.

## Review Focus

1. A ring while the listen-only RTSP feed is already open (someone tapped the person card): the feed closes and the call opens. Test in Task 6.
2. A double tap on Talk, or Talk tapped while the previous toggle is still connecting: one send connection at most. Test in Task 5.
3. Hang up while the receive connection is still connecting: the late link is closed, and the platform hold is released exactly once. Test in Task 5.
4. Hearth backgrounded with Talk live: the send connection closes and the view closes. Test in Task 6.
5. go2rtc refusing the camera (an `error` frame, e.g. an unknown stream): treated as a connect failure and falls back to RTSP. Tests in Tasks 4 and 6.

---

### Task 1: `ring` payload and NotificationService ring events

**Files:**
- Create: `lib/modules/cameras/doorbell/doorbell_support.dart`
- Modify: `lib/models/hearth_notification.dart`, `lib/services/notification_service.dart`
- Test: `test/models/hearth_notification_test.dart` (create it if missing), `test/services/notification_service_test.dart`

**Interfaces:**
- Produces: `bool get doorbellCallSupported` and `@visibleForTesting bool? debugDoorbellCallSupportedOverride`; `HearthNotification.ring` (bool, default false, copied by `updating`); a `NotificationService` constructor param `bool Function(HearthNotification)? honoursRing` (default `(_) => false`); `Stream<HearthNotification> get rings`; `Stream<String> get clears` (both broadcast).

- [ ] **Step 1: Write failing tests**
  - `fromIngest` gives `ring == true` for `{"title":"x","ring":true}`, and `false` for `"ring":"true"`, `"ring":1` or no `ring`.
  - `honoured ring bypasses a dismissed tag`: ingest a tagged card with `timeout: 180` and `camera`, `dismiss` it, then ingest the same tag with `ring: true` and `honoursRing: (_) => true`. The card is back, and `rings` emitted it once.
  - `unhonoured ring keeps dismissed suppression`: same, with `honoursRing: (_) => false`. No card, no emission.
  - `ring updating an existing card emits`: an existing tagged card updates in place (same id, list length 1), and `rings` emits.
  - `clear emits the tag`: `ingestPayload({"tag":"front_doorbell","clear":true})` emits `front_doorbell` on `clears`.
  - `payload without ring never emits on rings`.
- [ ] **Step 2: Run** `flutter test test/models/hearth_notification_test.dart test/services/notification_service_test.dart`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement.** Parse `ring` as `json['ring'] == true`. In `ingest`, when `notification.ring && _honoursRing(notification)`, cancel and remove the tag from `_dismissedTags` *before* the suppression check, then emit on `rings` after the card is stored or updated. `clear(tag)` emits on `clears`. Close both controllers in `dispose`. In `notificationServiceProvider`, pass `honoursRing: (n) => doorbellCallSupported && n.camera != null && ref.read(hubConfigProvider).frigateUrl.isNotEmpty`. Update the `fromIngest` doc comment's list of keys.
- [ ] **Step 4: Run** the same tests. Expected: PASS. Then run `flutter analyze lib/models lib/services lib/modules/cameras`.
- [ ] **Step 5: Commit** `feat(notifications): parse ring and emit doorbell rings (#315)`

### Task 2: Native hold (satellite pause, Sendspin mute, screen on, summon) and `DoorbellPlatform`

**Files:**
- Modify: `android/app/src/main/kotlin/com/hearth/hearth/voice/HearthAudioService.kt`, `.../voice/SatelliteBuilder.kt`, `.../sendspin/SendspinPlayer.kt`, `.../MainActivity.kt`
- Create: `android/app/src/main/kotlin/com/hearth/hearth/DoorbellChannel.kt`, `lib/modules/cameras/doorbell/doorbell_platform.dart`
- Test: `test/modules/cameras/doorbell/doorbell_platform_test.dart`

**Interfaces:**
- Produces (Kotlin): `HearthAudioService.callActive: MutableStateFlow<Boolean>` (companion, process-wide) and `HearthAudioService.setCallActive(active: Boolean)`, which sets the flow and calls `instance?.sendspinPlayer?.setCallMuted(active)`; `SendspinPlayer.setCallMuted(muted: Boolean)`, which calls `engine.setMuted(SyncAudioPlayer.MuteReason.VOICE, muted)`.
- Produces (channel `com.hearth/doorbell`): `begin` → null; `end` → null; `summon` with `{"title": String}` → null.
- Produces (Dart): `class DoorbellPlatform { Future<void> begin(); Future<void> end(); Future<void> summon(String title); }` and `final doorbellPlatformProvider = Provider<DoorbellPlatform>`. Every method returns at once when `!doorbellCallSupported`. `end` and `summon` log and swallow channel errors. `begin` rethrows, so the session can fail cleanly.

- [ ] **Step 1: Write failing Dart tests**, with `TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler`: `begin`, `end` and `summon('Doorbell rang at Front Door')` send those method names and the `{"title": …}` argument; `end` completes normally when the handler throws `PlatformException`; with `debugDoorbellCallSupportedOverride = false`, no call reaches the channel.
- [ ] **Step 2: Run** `flutter test test/modules/cameras/doorbell/doorbell_platform_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement Dart `DoorbellPlatform`.**
- [ ] **Step 4: Implement native.**
  - `SatelliteBuilder`: `muted = SettingState(combine(settings.muted, HearthAudioService.callActive) { m, held -> m || held }) { settings.muted.value = it }`. Ava's `VoiceInputImpl.start()` then stops and releases the `AudioRecord` while held. The mute switch entity keeps reading `settings.muted`, so Home Assistant sees no change.
  - `SendspinPlayer`: add `setCallMuted`, and apply `HearthAudioService.callActive.value` once the engine exists, so a Sendspin started mid-call starts muted.
  - `DoorbellChannel(activity, messenger)`:
    - `begin` runs `setCallActive(true)` and adds `FLAG_KEEP_SCREEN_ON` to the window; `end` reverses both.
    - `summon(title)`:
      - turns the screen on: `setTurnScreenOn(true)` and `setShowWhenLocked(true)`, plus a 10 s `SCREEN_BRIGHT_WAKE_LOCK | ACQUIRE_CAUSES_WAKEUP` wake lock (deprecated, but the only way to wake an already-stopped activity's screen);
      - then, if `!MainActivity.visible`, starts `AppSessionService.frontIntent(activity)` when `Settings.canDrawOverlays(activity)`;
      - otherwise posts a notification on a new `doorbell` channel (`IMPORTANCE_HIGH`, `CATEGORY_CALL`, `title` as the text, content intent opening `MainActivity`).
    - `dispose()` calls `end` first, so a detached engine never leaves the satellite paused.
  - `MainActivity`: create the channel in `configureFlutterEngine` and dispose it in `cleanUpFlutterEngine`, like the others.
  - Check the manifest already declares `WAKE_LOCK`, and add it if not.
- [ ] **Step 5: Run** the Dart tests (PASS), then `flutter build apk --debug`. Expected: `Built build/app/outputs/flutter-apk/app-debug.apk`.
- [ ] **Step 6: Commit** `feat(android): doorbell channel to pause the satellite, mute Sendspin and summon Hearth (#315)`

### Task 3: AudioCoordinator call mute

**Files:**
- Modify: `lib/services/audio_coordinator.dart`
- Test: `test/services/audio_coordinator_test.dart`

**Interfaces:**
- Produces: `void AudioCoordinator.setCallActive(bool active)`. While it is active, the playback factor is `0.0`, whatever the voice state.

- [ ] **Step 1: Write failing tests**: `call mutes playback` (factor becomes 0.0); `a voice duck during a call stays at 0`; `ending the call restores 1.0`, or `duckFactor` if the voice is active at that moment; `dispose restores 1.0`.
- [ ] **Step 2: Run** `flutter test test/services/audio_coordinator_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.** `_apply` returns `0.0` when `_callActive`, and otherwise keeps today's logic. Log `Doorbell call → muting playback` / `… restoring playback`.
- [ ] **Step 4: Run** the tests. Expected: PASS.
- [ ] **Step 5: Commit** `feat(audio): mute Hearth playback during a doorbell call (#315)`

### Task 4: go2rtc signalling and the WebRTC client

**Files:**
- Create: `lib/modules/cameras/doorbell/go2rtc_signaling.dart`, `lib/modules/cameras/doorbell/rtc_client.dart`
- Modify: `pubspec.yaml` and `pubspec.lock` (already staged in the worktree; see Global Constraints), `assets/licenses/notices.json`, `THIRD_PARTY_NOTICES.md` (regenerated)
- Test: `test/modules/cameras/doorbell/go2rtc_signaling_test.dart`

**Interfaces:**
- Produces:
  ```dart
  Uri go2rtcSignalingUri(String frigateUrl, String camera); // ws://<host>:1984/api/ws?src=<camera>
  sealed class Go2rtcMessage {}  // Go2rtcAnswer(String sdp), Go2rtcCandidate(String candidate), Go2rtcError(String message)
  class Go2rtcSignaling {
    Go2rtcSignaling(WebSocketChannel channel);
    Stream<Go2rtcMessage> get messages;
    void sendOffer(String sdp);
    void sendCandidate(String? candidate); // null → "" (end of candidates)
    Future<void> close();
  }
  class RtcUnavailable implements Exception { final String reason; }
  class MicDenied implements Exception {}
  abstract class RtcReceiveLink { Widget buildView(); Stream<void> get lost; Future<void> close(); }
  abstract class RtcTalkLink { Stream<void> get lost; Future<void> close(); }
  abstract class RtcClient {
    Future<RtcReceiveLink> receive(Uri signaling, {required Duration timeout});
    Future<RtcTalkLink> talk(Uri signaling, {required Duration timeout});
  }
  class FlutterWebrtcClient implements RtcClient {}
  final rtcClientProvider = Provider<RtcClient>((ref) => FlutterWebrtcClient());
  ```

- [ ] **Step 1: Write failing signalling tests**, using a fake `WebSocketChannel` in the style of `test/services/home_assistant_service_test.dart`:
  - `go2rtcSignalingUri('http://10.0.2.2:5000', 'FrontDoorbell')` is `ws://10.0.2.2:1984/api/ws?src=FrontDoorbell`;
  - `sendOffer('v=0…')` writes `{"type":"webrtc/offer","value":"v=0…"}`;
  - `sendCandidate(null)` writes `{"type":"webrtc/candidate","value":""}`;
  - incoming `webrtc/answer`, `webrtc/candidate` and `error` frames map to the three message types;
  - non-JSON and unknown types are dropped.
- [ ] **Step 2: Run** `flutter test test/modules/cameras/doorbell/go2rtc_signaling_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement `Go2rtcSignaling` and `go2rtcSignalingUri`.** Take the host the same way `FrigateCamera.fromEntry` does.
- [ ] **Step 4: Implement `FlutterWebrtcClient`.**
  - Once per process, call `WebRTC.initialize(options: {'androidAudioConfiguration': AndroidAudioConfiguration.media.toMap(), 'androidUseHardwareAudioProcessing': false})`.
  - Peer config: `{'bundlePolicy': 'max-bundle'}`, no ICE servers. Remote candidates get `sdpMid: '0'`. Each local candidate goes out with `sendCandidate`, and gathering's end with `sendCandidate(null)`.
  - `receive`: adds video and audio transceivers, both recvonly. `onTrack` feeds an `RTCVideoRenderer`. `buildView` returns `RTCVideoView(renderer, objectFit: contain)`.
  - `talk`: `navigator.mediaDevices.getUserMedia({'audio': {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true}, 'video': false})`. A failure here throws `MicDenied`. Then one audio transceiver, sendonly. On connect it requires the transceiver's `currentDirection` to be `sendonly` or `sendrecv`, as the Advanced Camera Card does; otherwise it throws `RtcUnavailable('no two-way audio')`.
  - Both links: they succeed when the connection state reaches `connected` within `timeout`, and close the signalling socket at that point. A `Go2rtcError`, a socket close before connect, or the timeout closes everything and throws `RtcUnavailable`. `failed` or `disconnected` after connect fires `lost`.
  - `close()` stops the tracks, disposes the stream and renderer, and closes the peer connection. It is idempotent.
  - This class runs only on a device; Task 9 verifies it.
- [ ] **Step 5: Notices.** Find the native WebRTC library flutter_webrtc pulls in for Android: read `flutter_webrtc-1.6.3/android/build.gradle` in the pub cache. Add an `assets/licenses/notices.json` entry for it (WebRTC, BSD-3-Clause, with the exact artifact and version). Run `dart run tool/gen_third_party_notices.dart`.
- [ ] **Step 6: Run** the signalling tests (PASS) and `flutter analyze lib/modules/cameras/doorbell`. Expected: no issues.
- [ ] **Step 7: Commit** `feat(cameras): go2rtc WebSocket signalling and WebRTC client (#315)`

### Task 5: DoorbellCallSession

**Files:**
- Create: `lib/modules/cameras/doorbell/doorbell_call_session.dart`
- Test: `test/modules/cameras/doorbell/doorbell_call_session_test.dart` (with a `FakeRtcClient`, a `FakeDoorbellPlatform` that implements `DoorbellPlatform`, and fake links that count `close()` calls)

**Interfaces:**
- Consumes: `RtcClient`, `RtcReceiveLink`, `RtcTalkLink`, `RtcUnavailable`, `MicDenied` (Task 4); `DoorbellPlatform` (Task 2).
- Produces:
  ```dart
  const kDoorbellConnectTimeout = Duration(seconds: 5);
  enum TalkResult { on, off, failed, micDenied }
  class DoorbellCallSession {
    DoorbellCallSession({required Uri signaling, required RtcClient rtc, required DoorbellPlatform platform,
        required void Function(bool active) muteHearthPlayback, void Function()? onLost, void Function()? onTalkLost});
    ValueListenable<RtcReceiveLink?> get media;
    ValueListenable<bool> get talking;
    Future<bool> start();          // begin + mute(true), then receive; false on any failure
    Future<TalkResult> setTalk(bool on);
    Future<void> dispose();        // idempotent; talk, receive, then end + mute(false) in finally
  }
  ```

- [ ] **Step 1: Write failing tests:**
  - `start holds the platform before connecting`: the order is `begin`, then `mute(true)`, then `receive`. `talk` is never called.
  - `start failure returns false and dispose still releases`: receive throws `RtcUnavailable`, so `start()` is false. `dispose()` then gives `end` once and `mute(false)` once.
  - `begin throwing returns false and dispose still releases`.
  - `talk on then off`: one `talk` call; `talking` goes true, then false; the talk link is closed and the receive link is not.
  - `double tap opens one send connection`: two `setTalk(true)` calls while the first is pending make one `talk` call.
  - `talk failure`: `RtcUnavailable` gives `TalkResult.failed` and `MicDenied` gives `TalkResult.micDenied`; `talking` stays false either way.
  - `talk lost after connect`: `talking` goes false and `onTalkLost` fires.
  - `receive lost after connect fires onLost`.
  - `dispose while talking`: the talk link closes before the receive link, `end` is called once, and `end` still runs when `talk.close()` throws.
  - `dispose during a pending receive`: the link that completes later is closed at once, and `end` is called once.
  - `setTalk after dispose` returns `off` and never calls `talk`.
- [ ] **Step 2: Run** `flutter test test/modules/cameras/doorbell/doorbell_call_session_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.** Serialize `setTalk` through one pending future. Track `_disposed` so late links get closed.
- [ ] **Step 4: Run** the tests. Expected: PASS.
- [ ] **Step 5: Commit** `feat(cameras): doorbell call session with satellite hold and talk link (#315)`

### Task 6: DoorbellCallController, provider and boot read

**Files:**
- Create: `lib/modules/cameras/doorbell/doorbell_call_controller.dart`
- Modify: `lib/main.dart` (boot read beside `foregroundSummonerProvider`)
- Test: `test/modules/cameras/doorbell/doorbell_call_controller_test.dart` (`fake_async`, with a fake session factory that records every created session and its dispose count)

**Interfaces:**
- Consumes: `DoorbellCallSession`, `TalkResult` (Task 5); `DoorbellPlatform.summon` (Task 2); `NotificationService.rings` and `.clears` (Task 1); `AudioCoordinator.setCallActive` (Task 3); `go2rtcSignalingUri`, `rtcClientProvider` (Task 4); `cameraFeedProvider`, `toastProvider`, `kCameraFeedMaxDuration`.
- Produces:
  ```dart
  const kDoorbellQuietTimeout = Duration(minutes: 3);
  const kRingSummonWindow = Duration(seconds: 15);
  @immutable class DoorbellCall { final String camera; final String? tag; final DateTime openedAt;
      final DoorbellCallSession session; final bool connected; final bool talkUsed; final bool talkOn; }
  class DoorbellCallController extends StateNotifier<DoorbellCall?> {
    DoorbellCallController({required DoorbellCallSession Function(String camera) createSession,
        required DoorbellPlatform platform, required bool Function() isForeground,
        required void Function() closeFeed, required void Function(String camera) fallbackToFeed,
        required void Function(String message) toast, DateTime Function()? now});
    void ring(HearthNotification ring);
    void clear(String tag);
    Future<void> setTalk(bool on);
    void hangUp();
    void onLifecycle(AppLifecycleState state);
  }
  final doorbellCallProvider = StateNotifierProvider<DoorbellCallController, DoorbellCall?>;
  ```

- [ ] **Step 1: Write failing tests**, all asserting that every closed session is disposed exactly once:
  - `ring in foreground opens and connects`: `closeFeed` is called, the session `start` runs, and `connected` becomes true.
  - `connect failure falls back`: `start` returns false, so the state is null, `fallbackToFeed('FrontDoorbell')` and `toast('Talk unavailable')` are called.
  - `receive lost falls back the same way`.
  - `quiet view closes at the payload timeout`: with `timeout` 180 s it is open at 179 s and null at 181 s. Without a `timeout`, it closes at 3 min.
  - `talk extends the life to 5 min from opening`: Talk at 170 s, so it is open at 181 s and 299 s, and null at 301 s.
  - `clear closes a quiet view`, and `clear leaves a view where talk was used`.
  - `second ring, other camera, talk off replaces`: the old session is disposed and a new one opens for `GarageDoorbell`.
  - `second ring, other camera, talk on is ignored`.
  - `repeat ring, same camera` keeps the same session and the same deadline.
  - `ring after hangUp opens a new view`.
  - `lifecycle hidden or paused closes, with talk on`: talk is set off and the session disposed. `inactive` keeps the view.
  - `ring in background summons`: `summon('Doorbell rang at Front Door')` is called and no session exists. `onLifecycle(resumed)` within 15 s opens the view; after 16 s it does nothing.
  - `talk denied`: `toast('Microphone permission needed')`, and `talkOn` stays false.
  - `talk failed`: `toast('Talk unavailable')`, and `talkOn` stays false.
  - `talk lost`: `talkOn` goes false with `toast('Talk unavailable')`.
- [ ] **Step 2: Run** `flutter test test/modules/cameras/doorbell/doorbell_call_controller_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement the controller.** Keep one deadline `Timer`, re-armed when Talk is first used. `talkUsed` is set when `setTalk(true)` returns `TalkResult.on`.
- [ ] **Step 4: Implement the provider.**
  - Subscribe to `notificationServiceProvider` `rings` and `clears`, and register an `AppLifecycleListener(onStateChange: controller.onLifecycle)`. Dispose both on `ref.onDispose`.
  - `isForeground`: `WidgetsBinding.instance.lifecycleState` is `resumed`, `inactive` or null.
  - `createSession` builds a `DoorbellCallSession` from `go2rtcSignalingUri(config.frigateUrl, camera)`, `rtcClientProvider`, `doorbellPlatformProvider`, and `ref.read(audioCoordinatorProvider).setCallActive`.
  - `fallbackToFeed` calls `cameraFeedProvider.notifier.open`. `toast` uses `toastProvider`, with `Icons.videocam_off` and `ToastType.warning`.
  - In `main.dart`: `if (doorbellCallSupported) container.read(doorbellCallProvider);`.
- [ ] **Step 5: Run** the tests (PASS), then all of `flutter test`. Expected: only the two known Windows-only failures (`third_party_notices_test` CRLF, `app_updater_test` "verified download is reused").
- [ ] **Step 6: Commit** `feat(cameras): doorbell call lifetime rules (#315)`

### Task 7: DoorbellCallOverlay and stacking

**Files:**
- Create: `lib/modules/cameras/doorbell/doorbell_call_overlay.dart`
- Modify: `lib/app/hub_shell.dart` (overlay stack), `test/portrait/overlays_portrait_test.dart`
- Test: `test/modules/cameras/doorbell/doorbell_call_overlay_test.dart`

**Interfaces:**
- Consumes: `doorbellCallProvider`, `DoorbellCall` (Task 6); `RtcReceiveLink.buildView` (Task 4).
- Produces: `class DoorbellCallOverlay extends ConsumerWidget { const DoorbellCallOverlay({super.key, required this.onWake}); }`, with widget keys `Key('doorbell-talk')` and `Key('doorbell-hangup')`.

- [ ] **Step 1: Write failing widget tests**, overriding `doorbellCallProvider` with a controller built on fakes:
  - with no call it renders nothing;
  - while connecting it shows the camera label and `Connecting…`;
  - tapping `doorbell-talk` calls `setTalk(true)`, and with `talkOn` the button reads `Talking`;
  - tapping `doorbell-hangup` calls `hangUp`;
  - tapping the video area leaves the view open;
  - `onWake` runs after the first frame.
- [ ] **Step 2: Run** `flutter test test/modules/cameras/doorbell/doorbell_call_overlay_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement the overlay.**
  - A full-screen black video backdrop, with `media` rendered through `ValueListenableBuilder`, and the camera label top-left in the `_CameraLabel` style without the back arrow.
  - Bottom row: Talk and Hang up, each at least 96 logical px tall. Talk is a toggle of at least 240 px with a mic icon and the text `Talk`. When live it shows `Talking`, a live dot and the accent fill.
  - Hang up shows `Icons.call_end` and the text `Hang up`, with a danger fill.
  - Colours from `context.hearthColors`.
  - Suppress idle while the view is mounted (`IdleController.suppress`/`unsuppress`, as `_FeedViewState` does).
  - Lay it out with `LayoutBuilder` so it holds at 1184x864, 864x1184 and 800x1280.
- [ ] **Step 4: Stack it.** In `hub_shell.dart`, add `DoorbellCallOverlay(onWake: _onUserActivity)` after `LiveTvOverlay`, and move `AlarmAlertOverlay` below it, so it is last. Add a comment that the call stays above casts so a live mic can't be hidden, and that the alarm stays topmost. Add the overlay to `overlays_portrait_test.dart` with an open, connected call.
- [ ] **Step 5: Run** the overlay tests, `flutter test test/portrait`, and `flutter test test/app/theme`. Expected: PASS.
- [ ] **Step 6: Commit** `feat(cameras): doorbell call view with Talk and Hang up (#315)`

### Task 8: Docs

**Files:**
- Modify: `docs/wiki/Notifications.md`, `docs/specs/2026-10-13-android-apk-requirements.md`, `CLAUDE.md`

- [ ] **Step 1: Wiki.**
  - Add a `ring` row to the payload table: `true`, with `camera`, on Android, to open the call view; ignored elsewhere; bypasses a dismissed card.
  - Add the doorbell automation example (the ring branch with `"ring": true`).
  - Add a "Doorbell call view" section: what opens it, Talk and Hang up, when it closes, the satellite pause and muted playback, the fallback, and the Pi behaviour.
- [ ] **Step 2: Android requirements.** Add a row for the doorbell call (status "unit-tested, emulator-checked" once Task 9 passes). In the follow-ups, add a real doorbell duplex test on the tablet.
- [ ] **Step 3: CLAUDE.md.** Update the layer 5 stacking order (…, DLNA cast, Plex cast, Live TV, doorbell call, alarm alert) and add a line on the doorbell call to the Android section.
- [ ] **Step 4: Commit** `docs: doorbell ring and call view (#315)`

### Task 9: Emulator verification against a local go2rtc

No kitchen tablet. Use the `wk2_panel` emulator with MQTT off. Pushing a config to it is fine; strip device identity.

- [ ] **Step 1: go2rtc in Docker on the dev PC.**
  - Image `alexxit/go2rtc`. Publish `1984/tcp` and `8555/tcp+udp`. Set `webrtc: candidates: ["10.0.2.2:8555"]`.
  - Stream `FrontDoorbell` with two sources:
    - a test source with H.264 video and Opus or PCMU audio (`ffmpeg` `testsrc` + `sine`);
    - a backchannel `exec:` source with `#backchannel=1`, which takes PCMU/PCMA from stdin and writes it to a file.
  - Check the exact `exec`/`#backchannel` syntax against the go2rtc README, not from memory.
  - Confirm `curl localhost:1984/api/streams` lists the stream.
- [ ] **Step 2: Hearth on the emulator.** Run `flutter build apk --debug` and `adb install`. Set `frigateUrl` to `http://10.0.2.2:5000` and turn MQTT off. Turn the voice satellite on, with an HA connection if one can be reached (see the emulator portproxy note), so its capture can be seen pausing and resuming.
- [ ] **Step 3: Ring.** Send `POST /api/notify` (via `adb forward tcp:8090 tcp:8090`) with `{"tag":"front_doorbell","title":"Doorbell rang at Front Door","camera":"FrontDoorbell","timeout":180,"ring":true}`. Expect the call view with the test pattern and the tone audible.
- [ ] **Step 4: Talk.** Tap Talk. `curl localhost:1984/api/streams?src=FrontDoorbell` should show a WebRTC consumer receiving audio, and the backchannel file should grow. Tap Talk again: that consumer is gone and the receive consumer stays.
- [ ] **Step 5: Hang up.** `adb shell dumpsys audio` should show no WebRTC recorder, and the satellite's `AudioRecord` back (or, without HA, the log line for the hold being released).
- [ ] **Step 6: Failure path.** Stop go2rtc and ring again. Expect the `Talk unavailable` toast and the RTSP feed's own unavailable toast.
- [ ] **Step 7:** Record what was verified and what was assumed in the Android requirements row (Task 8), then commit `docs: record emulator check of the doorbell call (#315)`.

### Task 10: PR

- [ ] Run `flutter analyze` and `flutter test`; results are as in Task 6 Step 5.
- [ ] Run `git -c credential.helper= -c credential.helper=manager push -u origin task/doorbell-ring-tap-to-talk`.
- [ ] Run `tea pr create --login registry --repo chris/Hearth --base main --head task/doorbell-ring-tap-to-talk -t "Doorbell ring: listen right away, tap to talk (Android)" -d "<summary, Closes #315, test plan, the WebSocket-signalling and alarm-reorder notes>"`.
