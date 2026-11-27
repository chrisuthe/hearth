# Doorbell ring: listen right away, tap to talk (Android)

From issue #315 (https://registry.home.chrisuthe.com/chris/hearth/issues/315), 2026-11-27. The decisions taken while planning are at the end.

## Why

When someone walks up to a doorbell, the kitchen Hearth shows a "Person Detected" picture card, and that should stay as it is. When they **press the button**, whoever is in the kitchen wants to hear them right away and answer by voice without going for a phone. The behaviour we want: a ring opens the doorbell's live video **with its sound playing**, and a big **Talk** button turns on the kitchen mic so you can answer.

This is the same pattern most Home Assistant wall-tablet intercoms use: show and listen first, then talk on one tap. A ring must never turn on the kitchen microphone by itself.

## Goals

- A doorbell ring opens a full-screen **doorbell call view** on Android Hearths at once, with the camera's live video and audio, no tap needed.
- A large **Talk** toggle sends the Hearth microphone to the doorbell. Tap once to talk, tap again to stop. Doorbell audio keeps playing while you talk (both directions open; see Constraints).
- A clear **Hang up** control closes the view and releases the mic.
- The voice satellite gives up the microphone while Talk is on and gets it back afterwards.
- Low delay in both directions: WebRTC straight to go2rtc on the LAN.

## Non-goals

- Pi Hearths. They have no WebRTC. On a Pi a `ring` payload behaves exactly as today: a card, and tapping it opens the existing listen-only RTSP feed. Nothing new to build there.
- Person-detected cards. Unchanged.
- Talking off the home network, and talking from phones (the HA dashboard already handles phones).
- Answering a ring on several Hearths at once, or deciding which Hearth "owns" the call. Every Android Hearth that gets the payload opens its own view.
- Recording or logging conversations.

## Anti-goals (a failure even if it technically works)

- The mic turning on without a tap on Talk.
- The mic staying on after Hang up, after the view times out, or after the app is backgrounded.
- Loud feedback or echo, from the doorbell's audio coming back out of the kitchen speaker into the mic.
- Breaking the voice satellite. Wake word detection must come back after every call, including calls that ended in an error.

## Current state (what the builder starts from)

- **Ring signal.** HA automation `hearth_kitchen_doorbell_person` (id in HA config) publishes to `hearth/<device-id>/notify` over MQTT. Its **ring** branch fires when `binary_sensor.doorbell_front_door_visitor` / `binary_sensor.doorbell_garage_visitor` turns on, and sends:
  `{"tag": "front_doorbell", "title": "Doorbell rang at Front Door", "image": "/api/camera_proxy/camera.frontdoorbell", "image_refresh": 3, "camera": "FrontDoorbell", "source": "frigate", "timeout": 180}`
  (`garage_doorbell` / `GarageDoorbell` for the garage). The person-detection branch sends the same shape with "Person Detected at …".
- **Ingest.** `NotificationService.ingestPayload` (`lib/services/notification_service.dart`) → `HearthNotification.fromIngest` (`lib/models/hearth_notification.dart`). Unknown fields are ignored today, so older Hearths will simply ignore a new field.
- **Feed.** Tapping a card with `camera` calls `CameraFeedController.open(camera, frame:)` (`lib/modules/cameras/camera_feed_overlay.dart`). `_FeedView` plays `rtsp://<frigate-host>:8554/<camera>` via `HearthVideoPlayer` (media_kit), with a 5-minute cap (`kCameraFeedMaxDuration`), an fps stall watchdog, idle suppression, and tap-anywhere-to-close.
- **Frigate/go2rtc.** `HubConfig.frigateUrl` (kitchen: `http://10.0.2.3:5000`). go2rtc's API is at `http://<same host>:1984` (see `FrigateCamera.fromEntry`). go2rtc stream names equal the Frigate camera names (`FrontDoorbell`, `GarageDoorbell`).
- **Doorbell side is already set up.** Both go2rtc streams have a talk-back (`audio, sendonly, PCMU/8000`) source from an RTSP backchannel. This was verified on 2026-11-27: the HA Advanced Camera Card on a phone sent mic audio through go2rtc to the Front Door doorbell and both people heard each other. go2rtc WebRTC listens on TCP 8555. It offers host candidate `10.0.2.3:8555` and UDP host candidates.
- **Microphone.** Android Hearth runs a native voice satellite (`VoiceSatelliteBridge`, `lib/services/voice_satellite_bridge.dart`; design in `docs/specs/2026-10-13-android-native-voice-satellite-design.md`). It holds the mic for wake word detection. `AudioCoordinator` ducks Hearth's own playback around it. `RECORD_AUDIO` and `FOREGROUND_SERVICE_MICROPHONE` are already in the manifest. `minSdk` is 29.

## Design (decided)

**Approach A: native WebRTC in Hearth via `flutter_webrtc`.** Considered and rejected:
- **B.** A bundled web page in the existing InAppWebView running go2rtc's player. Rejected: getUserMedia needs a secure origin, and go2rtc is plain `http://10.0.2.3:1984`, so it needs mixed-content and secure-origin workarounds. Mic coordination would also cross the WebView boundary.
- **C.** Keep the RTSP feed and send the mic to go2rtc some other way. Rejected: several seconds of delay on your voice.

1. **Payload.** Add an optional boolean `ring` to the ingest payload. With `ring: true` and a `camera`, an Android Hearth opens the doorbell call view for that camera straight away, on top of showing/updating the card as today. `ring` is ignored without `camera`. The HA automation's ring branch adds `"ring": true`. That HA change is done separately, outside the repo, once Hearth ships.
2. **Call view.** A new full-screen view (a call mode of the camera feed overlay, or its own overlay; builder's choice). It shows:
   - the live video;
   - the camera label;
   - a large **Talk** toggle, off by default, clearly showing when the mic is live;
   - a **Hang up** button.
   Tap-anywhere-to-close does **not** apply in this view.
3. **Media.** On open, one `RTCPeerConnection` to go2rtc (`POST http://<frigate-host>:1984/api/webrtc?src=<camera>` with the SDP offer; the response body is the answer) with recvonly video + audio. Doorbell audio plays at once, through the loudspeaker.
4. **Talk.** Turning Talk on opens a **second**, sendonly-audio peer connection to the same `src`, carrying the mic (`getUserMedia` with echo cancellation, noise suppression and auto gain on). This mirrors the Advanced Camera Card, which go2rtc here is proven to accept. Turning Talk off closes that connection and releases the mic. The receive connection is untouched throughout.
5. **Satellite handoff.** The voice satellite stops capturing when the call view opens, before any audio plays (see 12). It resumes when the view closes, whether by hang up, timeout or error. Whatever mechanism is used, the satellite must come back even if the call path throws.
6. **Lifetime.**
   - The view closes on Hang up.
   - If Talk was never turned on, it closes after the payload's `timeout` (180 s from HA), or after 3 minutes if there's no `timeout`.
   - Once Talk has been used, the existing 5-minute feed cap applies from the time the view opened.
   - A `clear` for the same tag does not close a view where Talk has been used.
   - Hearth going to the background ends Talk and closes the view (see 13).
7. **Second ring.** A ring for a different camera while a view is open replaces it, unless Talk is on, in which case the new ring only shows its card. A repeat ring for the same camera leaves the open view alone.
8. **Failure.** If WebRTC can't connect within ~5 s, fall back to today's RTSP feed (listen only), with a short toast "Talk unavailable". If only the Talk connection fails, keep listening, turn the toggle back off, and toast. If the `RECORD_AUDIO` permission is missing or denied, Talk shows a toast and stays off.
9. **Platforms.** On non-Android platforms, `ring` is ignored and today's behaviour stays.
10. **Repeat rings and dismissed cards.** The ring branch shares its `tag` with the person-detected card (`front_doorbell` / `garage_doorbell`). It sends `ring: true` once per button press, on the visitor sensor's off→on edge. It doesn't re-send `ring` on the heartbeat, which only re-sends the person card. So:
    - every `ring: true` is a fresh press and opens the view, **bypassing** the dismissed-tag suppression in `NotificationService.ingest`, for both the card and the view;
    - Hang up holds until the next press;
    - payloads without `ring` keep today's dismissed-tag behaviour.
11. **Other audio while the view is open.** Hearth's own playback on that device is muted or paused while the call view is open, and restored when it closes, so music doesn't leak into the mic or drown the visitor. That covers media_kit players, Sendspin (native mute) and DLNA/Plex casts. A cast that starts while the view is open doesn't close it.
12. **Satellite for the whole view.** The voice satellite stops capturing for the **whole time the call view is open**, not only while Talk is on, so the doorbell's audio from the loudspeaker can't trigger the wake word. It resumes when the view closes, on every path.
13. **Foreground and screen.**
    - A ring wakes the display and brings Hearth to the front (as an alarm would). If Hearth can't come forward, e.g. "Display over other apps" isn't granted, the card and a system notification are enough and no audio plays from the background.
    - While the view is open it keeps the screen on.
    - Only Hearth going to `paused`/background ends Talk and closes the view. `inactive` (split screen, another window focused) does not.
14. **Mic mute.** Talk works even while the satellite mic is muted (`micMuted`), because tapping Talk is an explicit choice by someone in the room. Pausing and resuming the satellite must **not** change `micMuted` or the mute state reported to Home Assistant, so `setMuted` is not the pause mechanism.
15. **Docs.** Document `ring` in `docs/wiki/Notifications.md` (payload table + doorbell example) and add a short section on the call view.

## Constraints

- **Dependency.** Add `flutter_webrtc` to `pubspec.yaml`, which was agreed with the owner. It isn't federated, so the Windows dev build also gets its native WebRTC library. That's accepted. CI builds only the Pi asset bundle and the APK, so neither is affected. Calls into it must be Android-only at runtime.

- **Duplex.** Reports from other Reolink PoE doorbell intercoms say both directions work at once. The real risk is echo, so echo cancellation is required, not optional. Duplex hasn't been tested with this exact doorbell yet. If testing shows the doorbell drops its own audio while the mic sends, that's a hardware limit to document, not a bug to work around.
- **Audio routing.** On Android, WebRTC audio can switch the device into communication mode and route to an earpiece or a quieter stream. On these tablets it must play from the loudspeaker at a usable volume. Restore the previous audio mode when the view closes.
- **No mic outside an active Talk.** This also rules out pre-warming getUserMedia.
- **No credentials needed.** go2rtc on the LAN is unauthenticated. Don't add any.
- **Testing.**
  - Don't run test builds on the kitchen Apolosign tablet. Use the project emulators (e.g. `wk2_panel`) and turn off MQTT or other identity-bearing features on them.
  - The Android emulator's own network is `10.0.2.0/24` and `10.0.2.3` is the emulator's DNS, so the emulator **cannot** reach the real go2rtc at `10.0.2.3`. Test against a go2rtc reachable from the emulator, e.g. a local go2rtc on the dev PC reached via the host alias `10.0.2.2`, with any test source. You can also inject a ring by MQTT/`POST /api/notify` with `ring: true`.
  - A real doorbell test happens on the tablet after release, by the user.
- **Conventions.** Commits and PRs are written as the user, with no AI attribution lines. PRs go to Gitea (`tea --login registry --repo chris/Hearth`). Follow `CLAUDE.md`.

## Left to the builder

- Whether the call view is a mode of `CameraFeedOverlay` or a sibling overlay, and how it's layered relative to the alarm/cast overlays (alarm should stay on top).
- The exact mechanism for pausing and resuming the satellite's capture (bridge method, native change, or reuse of an existing path), within requirement 5.
- How to set loudspeaker routing and the volume source.
- Visual design of Talk/Hang up, within the existing Hearth style. Talk must be large and readable from across a kitchen.
- How to make the WebRTC client testable (an injected signalling/peer factory is expected so unit tests don't need a real peer).

## Done when

- Unit tests cover:
  - `ring` parsing;
  - Android vs other-platform routing;
  - Talk on/off opening and closing the send connection;
  - satellite pause/resume for the whole view, including on errors and on view close, without changing `micMuted`;
  - lifetime rules (timeout, cap, clear, second ring, ring after a dismissed card, ring after Hang up);
  - other playback muted while the view is open and restored after;
  - fallback to RTSP on WebRTC failure.
- On the emulator against a test go2rtc:
  - a `ring` payload opens the call view with video and audio;
  - Talk sends mic audio, which shows as a WebRTC consumer receiving audio in go2rtc's `/api/streams`;
  - Hang up releases the mic;
  - the satellite resumes.
- The wiki is updated, and a PR is open on Gitea.

## Decided during planning (2026-11-27)

Checked against the go2rtc source (`internal/webrtc/server.go`, `webrtc.go`) and the Advanced Camera Card source (`src/components-lib/live/backchannel/go2rtc.ts`), not assumed.

- **Signalling is go2rtc's WebSocket (`ws://<host>:1984/api/ws?src=<camera>`), for both connections, not `POST /api/webrtc`.** `POST /api/webrtc` picks the role from the offer (`IsConsumer`): an offer that only *sends* audio is registered as a **producer**, so its audio would never reach the doorbell's backchannel. The WebSocket with `src=` always registers a **consumer**, which is how the Advanced Camera Card's own send-only backchannel connection reaches the doorbell. The message format is go2rtc's v1: `{"type":"webrtc/offer","value":<sdp>}` out; `webrtc/answer`, `webrtc/candidate` and `error` back; local candidates sent as `webrtc/candidate`, an empty value ending them. The socket closes once the peer connection is connected, as the card does.
- **Audio routing:** `WebRTC.initialize` with `AndroidAudioConfiguration.media` (audio mode `normal`, `STREAM_MUSIC`, usage media) and `androidUseHardwareAudioProcessing: false`. Playback goes to the loudspeaker at the media volume, the audio mode never leaves `normal` (nothing to restore), and echo cancellation is WebRTC's software canceller, which takes WebRTC's own playout as its reference. The Talk track asks for `echoCancellation`, `noiseSuppression` and `autoGainControl`.
- **Satellite pause:** a process-wide `HearthAudioService.captureHeld` flow, OR'd with the mute setting into the `muted` that Ava's `VoiceInputImpl` sees. Ava stops and releases the `AudioRecord` while it is true. `settings.muted`, the "Mute Microphone" switch and `micMuted` are untouched. Dart holds it for the life of the call and releases it in a `finally`. The native channel also releases it when the Flutter engine detaches.
- **Muting other playback:** media_kit players (casts included) through `AudioCoordinator`, which goes to 0 while a call is open. Sendspin through the engine's `VOICE` mute reason, which Hearth did not use until now.
- **Layering:** the call view sits above the cast and Live TV overlays, so a cast that starts during a call cannot hide it, or hide a live mic. The alarm overlay moves to the top of the stack so it stays above the call view. This also puts it above casts, which it was not before.
- **Coming forward:** a native `summon` call turns the screen on and brings Hearth forward ("Display over other apps" is needed when another app is in front). If Hearth is still not visible, it posts a high-priority system notification. Dart opens the view only while Hearth is visible, and holds a ring for 15 s waiting for it to come forward.
- **`ring` is honoured only with a `camera`, on Android, with a Frigate URL set.** Everywhere else it is ignored, including the dismissed-tag bypass.
