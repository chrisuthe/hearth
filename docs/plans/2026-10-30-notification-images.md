# Notification Images and Camera Cards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a notification carry a picture from Home Assistant that refreshes in place, and let a tap open that camera's Frigate feed full screen.

**Architecture:** New optional payload fields flow through one shared ingest path into `NotificationService`, which gains tags, in-place updates, `clear`, `timeout` and dismissed-tag memory. A new loader fetches pictures with strict token rules, a new picture widget polls it inside the card, and a new layer-5 overlay plays the feed, showing the card's last frame until video appears.

**Tech Stack:** Flutter 3.47.7, Riverpod, Dio, `flutter_test`. Run tests with `flutter test`. Flutter is not on the shell's `PATH` on the dev machine, so use `C:\flutter\bin\flutter.bat`.

**Spec:** `docs/specs/2026-10-30-notification-images-design.md`

## Global Constraints

- Existing payloads behave exactly as they do today. Existing notification tests pass unchanged.
- Hearth's HA token is only ever sent to the origin of the configured `haUrl`, never on a followed redirect.
- `image_refresh` values under 1 are treated as 1.
- A card with `image_refresh` and no `timeout` gets a 10-minute timeout.
- The feed closes on a tap, on the stall watchdog, or after 5 minutes.
- The feed starts on the tap, never when a notification arrives.
- Only one RTSP decoder runs at a time.
- Layouts hold at 1184x864, 864x1184 and 800x1280 (`test/portrait/`).
- Video surfaces mark literal colours `// theme-exempt: video`. Card colours come from `NotifColors`.
- Commit messages follow the repo's `feat(scope): ...` style with no attribution lines.

**One refinement to the spec, applied in Task 5:** dismissed tags are only remembered when the card has a `timeout`. Otherwise an automation using `tag` with no `clear` would have its card silenced until restart.

## Review Focus

- `image` set to `//evil.example/x` or `/\evil.example/x`: must be treated as another origin and never receive the token (test in Task 2).
- HA answering 200 with an HTML login page, or 401 after a token change: the card keeps its last frame or falls back to text (tests in Tasks 2 and 4).
- Wrongly typed new fields, such as `"image": 5`, `"image_refresh": "abc"`, `"tag": ""`: treated as absent with no exception, since an exception would break the MQTT handler (test in Task 1).
- A heartbeat for a dismissed tag: no `notifyListeners`, so the deck does not wake the screen and the Android foreground summoner does not fire (test in Task 1).
- A card removed or a feed closed while a fetch or `play()` is in flight: no `setState` after dispose, no late toast, and the player is released (tests in Tasks 3 and 4).

---

### Task 1: Payload fields and service behaviour

**Files:**
- Modify: `lib/models/hearth_notification.dart`
- Modify: `lib/services/notification_service.dart`
- Modify: `lib/services/mqtt_service.dart:683-725`
- Modify: `lib/services/local_api_server.dart:700-734`
- Test: `test/models/hearth_notification_test.dart` (create), `test/services/notification_service_test.dart`, `test/services/mqtt_service_test.dart`, `test/services/local_api_server_test.dart`

**Interfaces:**
- Produces on `HearthNotification`: `String? image`, `Duration? imageRefresh`, `String? camera`, `String? tag`, `Duration? timeout`, all optional constructor arguments.
- Produces: `static String idForTag(String tag)` returning `'tag-$tag'`.
- Produces on `NotificationService`: `String? ingestPayload(Map<String, dynamic> json)` returning the affected card id, or null when the payload is invalid. `void clear(String tag)`.

- [ ] **Step 1: Write failing model tests** in `test/models/hearth_notification_test.dart`:

```dart
test('parses the new fields', () {
  final n = HearthNotification.fromIngest({
    'title': 'Person', 'tag': 'front_door', 'camera': 'front_door',
    'image': '/api/camera_proxy/camera.front_door',
    'image_refresh': 3, 'timeout': 180,
  })!;
  expect(n.id, 'tag-front_door');
  expect(n.imageRefresh, const Duration(seconds: 3));
  expect(n.timeout, const Duration(seconds: 180));
  expect(n.sticky, isTrue);
});
test('image_refresh under 1 becomes 1', ...);        // 0.2 -> 1s
test('image_refresh with no timeout gets 10 minutes', ...);
test('timeout beats sticky:false', ...);             // sticky is true
test('wrong types and empty strings count as absent', () {
  final n = HearthNotification.fromIngest({
    'title': 'x', 'image': 5, 'image_refresh': 'abc',
    'camera': '', 'tag': '', 'timeout': -1,
  })!;
  expect(n.image, isNull); expect(n.imageRefresh, isNull);
  expect(n.camera, isNull); expect(n.tag, isNull); expect(n.timeout, isNull);
  expect(n.id, startsWith('ext-'));
});
test('numeric strings are accepted', ...);           // "3" -> 3s
test('existing payload is unchanged', ...);          // no new fields set, sticky rules as before
```

- [ ] **Step 2: Write failing service tests** in the existing `NotificationService` group, using the `make` helper extended with `tag` and `timeout` (`id` is `HearthNotification.idForTag(tag)` when tagged):

```dart
test('same tag updates in place with no second chime', ...);
  // ingest a, ingest tagged, ingest b, re-ingest tagged with a new title:
  // order stays a, tagged, b; title is new; chimed.length is 3.
test('same-tag update keeps the original timestamp', ...);
test('timeout closes the card and restarts on update', ...);
test('clear removes the card and is idempotent', ...);
test('dismissed tag ignores updates without notifying', () async {
  // ingest tagged with timeout, dismiss(id), add a listener counting notifies,
  // ingest same tag again.
  expect(service.notifications, isEmpty);
  expect(notifyCount, 0);
  expect(chimed.length, 1);
});
test('clear forgets a dismissed tag', ...);          // next ingest is a new card, chimes
test('timeout forgets a dismissed tag', ...);        // same, after timeout with no update
test('an update restarts the dismissed-tag timeout', ...);
test('a tag with no timeout is not remembered after dismiss', ...);
test('a card closed by timeout is not remembered', ...);
test('ingestPayload with clear and tag clears', ...);
test('ingestPayload with clear and no tag returns null', ...);
test('ingestPayload with no title or message returns null', ...);
```

- [ ] **Step 3: Add transport tests.** In `mqtt_service_test.dart`: `notify with clear closes the tagged card`. In `local_api_server_test.dart`: `POST /api/notify clear returns 200`, and `POST /api/notify clear with no tag returns 400`.

- [ ] **Step 4: Run them to confirm they fail**

Run: `flutter test test/models/hearth_notification_test.dart test/services/notification_service_test.dart test/services/mqtt_service_test.dart test/services/local_api_server_test.dart`
Expected: FAIL on the new tests with missing members.

- [ ] **Step 5: Implement the model.** In `fromIngest`, parse new fields with tolerant private helpers: a string helper that returns null for non-strings and blanks, and a seconds helper that accepts `num` or a numeric string and returns null for anything else or for values at or below 0. Clamp `image_refresh` up to 1 second. Default `timeout` to 10 minutes when `imageRefresh` is set. Force `sticky` true when `timeout` is set. Use `idForTag` for the id when tagged. Remove the "Camera fields are intentionally absent" comment.

- [ ] **Step 6: Implement the service.** Keep `dismiss` as the user path and add a private removal that the timers and `clear` use.
  - `ingest`: if the tag is in `_dismissedTags`, restart that tag's timer from the new `timeout`, then return with no notify. If a card with the same tag exists, replace it at the same index with the existing card's `timestamp` and `onDismiss` carried over, restart its timer, notify, and do not chime. Leave the existing untagged replace path as it is, including its chime.
  - Timers: arm `timeout` when set, otherwise the existing transient lifetime when not sticky.
  - `dismiss(id)`: when the card has a tag and a `timeout`, record the tag in `_dismissedTags: Map<String, Timer>` with a timer of that `timeout`.
  - `clear(tag)`: remove the card without remembering it and cancel any memory timer.
  - `dispose`: cancel the memory timers too.
  - `ingestPayload`: `clear: true` with a valid tag calls `clear` and returns `idForTag(tag)`. `clear: true` without a tag returns null. Otherwise use `fromIngest` and `ingest`. A `clear` value other than `true` is ignored.

- [ ] **Step 7: Route both transports through `ingestPayload`.** `_handleNotify` in each keeps its current rejection behaviour for null. Update both schema comments with the new fields.

- [ ] **Step 8: Run the tests**

Run: the Step 4 command, then `flutter test test/services/foreground_summoner_test.dart test/services/timer_service_test.dart`
Expected: all PASS.

- [ ] **Step 9: Commit**

```bash
git add lib/models/hearth_notification.dart lib/services/notification_service.dart lib/services/mqtt_service.dart lib/services/local_api_server.dart test/models/hearth_notification_test.dart test/services/notification_service_test.dart test/services/mqtt_service_test.dart test/services/local_api_server_test.dart
git commit -m "feat(notifications): add tags, clear, timeout and image fields to ingest"
```

### Task 2: Picture loader

**Files:**
- Create: `lib/services/notification_image_loader.dart`
- Test: `test/services/notification_image_loader_test.dart`

**Interfaces:**
- Produces: `class NotificationImageLoader { NotificationImageLoader({required String haUrl, required String haToken, Dio? dio}); Future<Uint8List?> fetch(String image); void dispose(); }`
- Produces: `final notificationImageLoaderProvider = Provider<NotificationImageLoader>`, watching only `haUrl` and `haToken` through `select`, disposing on `ref.onDispose`.

- [ ] **Step 1: Write failing tests**, using a fake `HttpClientAdapter` in the style of `test/modules/calendar/ha_calendar_source_test.dart` that returns `image/jpeg` bytes and records requests:

```dart
const ha = 'http://ha.local:8123';
test('relative path goes to HA with the token', ...);
  // uri http://ha.local:8123/api/camera_proxy/camera.x, Authorization: Bearer t
test('same-origin absolute URL gets the token', ...);
test('other origin gets no token', ...);              // http://photos.local/a.jpg
test('different port counts as another origin', ...); // http://ha.local:9000/a.jpg
test('protocol-relative path never gets the token', ...); // //evil.example/x
test('backslash path never gets the token', ...);     // /\evil.example/x
test('non-http scheme is not fetched', ...);          // file:///etc/passwd, no request
test('relative path with no HA URL or token is not fetched', ...);
test('redirects are not followed when the token is attached', ...);
  // options.followRedirects is false on the recorded request
test('non-image response returns null', ...);         // text/html with 200
test('error status returns null', ...);               // 401
test('response over the size cap returns null', ...); // 11 MB body
test('adapter exception returns null', ...);
```

For the protocol-relative and backslash cases, assert no recorded request carries an `Authorization` header.

- [ ] **Step 2: Run them to confirm they fail**

Run: `flutter test test/services/notification_image_loader_test.dart`
Expected: FAIL, the file does not exist.

- [ ] **Step 3: Implement.** Resolve with `Uri.parse(haUrl).resolve(image)` when `image` starts with `/`, then compare scheme, host and effective port against `haUrl` for every case. The token goes only on a same-origin result. Accept only `http` and `https`. Use `ResponseType.stream`, read up to a 10 MB cap, cancel past it, connect timeout 5 seconds, receive timeout 10 seconds, `followRedirects: false` when the token is attached. Require a `content-type` starting `image/`. Catch all failures, return null and log with `Log.w`, without the token.

- [ ] **Step 4: Run the tests**

Run: `flutter test test/services/notification_image_loader_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/notification_image_loader.dart test/services/notification_image_loader_test.dart
git commit -m "feat(notifications): fetch notification pictures with scoped HA auth"
```

### Task 3: Live feed overlay

**Files:**
- Create: `lib/modules/cameras/camera_feed_overlay.dart`
- Modify: `lib/app/hub_shell.dart:544-548`
- Modify: `lib/modules/cameras/cameras_screen.dart`, `lib/modules/protect/protect_screen.dart`
- Test: `test/modules/cameras/camera_feed_overlay_test.dart`, `test/portrait/overlays_portrait_test.dart`

**Interfaces:**
- Produces: `class CameraFeedRequest { final String camera; final Uint8List? frame; }`
- Produces: `class CameraFeedController extends StateNotifier<CameraFeedRequest?> { void open(String camera, {Uint8List? frame}); void close(); }`, with `cameraFeedProvider`. `open` is a no-op while a feed is already open.
- Produces: `class CameraFeedOverlay extends ConsumerWidget { const CameraFeedOverlay({super.key, required this.onWake}); }`

- [ ] **Step 1: Write failing tests.** Use `registerVideoPlayerFactory(mediaKit: () => fake)` with a `HearthVideoPlayer` fake in the style of `test/services/video/video_fit_test.dart`, whose `play` completes on demand, and a `FrigateService` subclass in the style of `test/portrait/module_cameras_portrait_test.dart`:

```dart
testWidgets('renders nothing and creates no player until opened', ...);
testWidgets('shows the supplied frame before video appears', ...);
  // find.byType(Image) present, fake.buildView not yet in the tree
testWidgets('shows video once videoSize is known', ...);
testWidgets('tap closes, disposes the player and unsuppresses idle', ...);
testWidgets('closes after 5 minutes', ...);          // pump(Duration(minutes: 5))
testWidgets('stays open past 4 minutes 59', ...);
testWidgets('play returning false closes and shows a toast', ...);
testWidgets('no frigateUrl closes and shows a toast', ...);
testWidgets('a stalled camera closes and shows a toast', ...); // fps 0 for 10s
testWidgets('closing during play() leaves no toast and disposes once', ...);
testWidgets('a starting Plex cast closes the feed', ...);
testWidgets('open is ignored while a feed is open', ...);
```

Also add to `cameras_screen` coverage in the same file: `opening a feed collapses an expanded camera and leaves idle suppressed`.

- [ ] **Step 2: Run them to confirm they fail**

Run: `flutter test test/modules/cameras/camera_feed_overlay_test.dart`
Expected: FAIL, the file does not exist.

- [ ] **Step 3: Implement the controller and overlay.** `CameraFeedOverlay` watches the provider, returns `SizedBox.shrink()` when null, and otherwise a `Positioned.fill` with a private `_FeedView` keyed on the request, so the player's lifetime matches the widget's. It calls `onWake` from a post-frame callback, as `LiveTvOverlay` does.

`_FeedView` details:
  - Capture the idle controller in `initState`. Call `suppress()` in a post-frame callback, so it lands after `CamerasScreen` has collapsed and unsuppressed. Call `unsuppress()` in `dispose`.
  - Build the URL with `FrigateCamera.fromEntry(camera, frigateUrl).rtspUrl`.
  - Failure: close first, then show a `'$camera stream unavailable'` toast, because `ToastOverlay` sits below this overlay.
  - Body: black backdrop, the frame with `Image.memory(fit: BoxFit.contain)`, and `player.buildView(fit: BoxFit.contain)` on top once `videoSize` is non-null. Camera name chip and LIVE badge as in `CamerasScreen`.
  - Watchdog: same 3-second poll and 10-second grace as `CamerasScreen`, closing with a `'$camera stream offline'` toast. Keep this separate from the screen's copy rather than refactoring `CamerasScreen`.
  - `ref.listen` on `dlnaRendererStateProvider`, `plexPlayerStateProvider` and `plexLiveTvStateProvider`, closing when `hasMedia` becomes true.
  - A `Timer(const Duration(minutes: 5), close)`.
  - `dispose` cancels both timers and disposes the player. Check `mounted` after awaiting `play`.

- [ ] **Step 4: Wire it in.** In `hub_shell.dart`, add `CameraFeedOverlay(onWake: _onUserActivity)` directly after `NotificationDeckOverlay`. In `CamerasScreen.build` and `ProtectScreen.build`, `ref.listen(cameraFeedProvider, ...)` and call `_collapseCamera()` when it becomes non-null with a camera expanded.

- [ ] **Step 5: Add the portrait test.** In `overlays_portrait_test.dart`, add `group('Camera feed')` using `testLayouts` for an open feed with a frame and a long camera name, overriding `cameraFeedProvider` with an already-open controller and registering a fake player.

- [ ] **Step 6: Run the tests**

Run: `flutter test test/modules/cameras/camera_feed_overlay_test.dart test/portrait/overlays_portrait_test.dart test/portrait/module_cameras_portrait_test.dart`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/modules/cameras/camera_feed_overlay.dart lib/app/hub_shell.dart lib/modules/cameras/cameras_screen.dart lib/modules/protect/protect_screen.dart test/modules/cameras/camera_feed_overlay_test.dart test/portrait/overlays_portrait_test.dart
git commit -m "feat(cameras): add full-screen camera feed overlay"
```

### Task 4: Picture on the card, and tap to open

**Files:**
- Create: `lib/widgets/notification_picture.dart`
- Modify: `lib/widgets/notification_card.dart`, `lib/widgets/notification_deck_overlay.dart`, `lib/app/tokens/notification_tokens.dart`
- Test: `test/widgets/notification_picture_test.dart`, `test/widgets/notification_card_test.dart`, `test/portrait/overlays_portrait_test.dart`, `test/portrait/portrait_fixtures.dart`

**Interfaces:**
- Consumes: `notificationImageLoaderProvider` and `NotificationImageLoader.fetch` (Task 2), `cameraFeedProvider` (Task 3), the new `HearthNotification` fields (Task 1).
- Produces: `class NotificationPicture extends ConsumerStatefulWidget { const NotificationPicture({super.key, required String image, Duration? refresh, bool showPlayIcon = false, ValueChanged<Uint8List>? onFrame}); }`
- Produces: on `NotificationCard`, an optional `ValueChanged<Uint8List?>? onOpenFeed`. Non-null means the card is tappable.

- [ ] **Step 1: Write failing tests.** Override `notificationImageLoaderProvider` with a scripted fake loader:

```dart
testWidgets('shows the fetched frame', ...);
testWidgets('refresh replaces the frame', ...);       // pump(3s), fetch count 2, new bytes shown
testWidgets('no refresh fetches once', ...);
testWidgets('a failed refresh keeps the last frame', ...);
testWidgets('never loading collapses to nothing', ...); // SizedBox.shrink, no placeholder left
testWidgets('fetches do not overlap', ...);           // slow fetch, pump past interval, count 1
testWidgets('polling pauses while a feed is open and resumes after', ...);
testWidgets('dispose during a fetch does not throw', ...);
testWidgets('a changed image address fetches the new one', ...);
```

And in `notification_card_test.dart`:

```dart
testWidgets('card with no image renders as it does today', ...);
testWidgets('tap fires onOpenFeed with the latest frame', ...);
testWidgets('tap with no camera does nothing', ...);
testWidgets('the close button dismisses without opening the feed', ...);
testWidgets('pill reads Tap for live view with a camera', ...);
testWidgets('mute state survives an in-place update', ...);
testWidgets('in-place update does not replay the entrance', ...); // on the deck
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `flutter test test/widgets/notification_picture_test.dart test/widgets/notification_card_test.dart`
Expected: FAIL.

- [ ] **Step 3: Implement `NotificationPicture`.** Fetch on `initState`, poll on `refresh`, skip overlapping fetches, reset on a changed `image`, and pause while `ref.watch(cameraFeedProvider.select((f) => f != null))` is true. While the first fetch is pending, reserve the box with `NotifColors.pictureBackdrop` (add this token, black). If it fails with no frame yet, render `SizedBox.shrink()`. A failed refresh keeps the last frame.

The box is full width with height `min(width * 9 / 16, MediaQuery.sizeOf(context).height * 0.5)`, using `LayoutBuilder` for the width. Render with `Image.memory(fit: BoxFit.contain, gaplessPlayback: true, cacheWidth: <box width x device pixel ratio>)`, so a 4:3 doorbell frame is never cropped. Centre `Icons.play_circle_outline` when `showPlayIcon`.

- [ ] **Step 4: Update the card.** Inside the `ClipRRect`, the column becomes the picture (outside the padding) followed by the existing padded content. Move the accent rail after the content in the `Stack` so it paints over the picture. Hold the latest frame in a field, not in `setState`. Wrap in a `GestureDetector(onTap: ...)` only when `onOpenFeed` is non-null. Pill text is `'Tap for live view'` when tappable, otherwise as today. Remove the "camera row deferred" wording from the class comment. A card with no `image` must be unchanged.

- [ ] **Step 5: Update the deck.** Pass `onOpenFeed` when `n.camera != null`, calling `ref.read(cameraFeedProvider.notifier).open(n.camera!, frame: frame)`. For a card with an `image`, when `MediaQuery` width is greater than height, centre it with `maxWidth` of 56% of the canvas width. Otherwise leave it full width.

- [ ] **Step 6: Add portrait coverage.** Add `sampleCameraNotification()` to `portrait_fixtures.dart` and a `testLayoutsAndSplitHalves('a camera card above two text cards', ...)` to the deck group, with a fake loader returning a 4:3 PNG.

- [ ] **Step 7: Run the tests**

Run: `flutter test test/widgets/notification_picture_test.dart test/widgets/notification_card_test.dart test/portrait/overlays_portrait_test.dart test/app/theme/theme_literal_guard_test.dart`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/widgets/notification_picture.dart lib/widgets/notification_card.dart lib/widgets/notification_deck_overlay.dart lib/app/tokens/notification_tokens.dart test/widgets/notification_picture_test.dart test/widgets/notification_card_test.dart test/portrait/overlays_portrait_test.dart test/portrait/portrait_fixtures.dart
git commit -m "feat(notifications): show refreshing pictures and open the feed on tap"
```

### Task 5: Docs and full verification

**Files:**
- Modify: `docs/wiki/Notifications.md`, `docs/wiki/Home-Assistant-Device-(MQTT).md` (only if its notify row needs it), `CLAUDE.md:41`
- Modify: `docs/specs/2026-10-30-notification-images-design.md`

- [ ] **Step 1: Update the wiki.** In `Notifications.md`: add the six fields to the payload table, a "Pictures and camera cards" section with the spec's reference automation, the token rule, the heartbeat and dismissed-card behaviour, and the feed's 5-minute limit. Note that the sensor entity ID must be the user's own.

- [ ] **Step 2: Update `CLAUDE.md`** line 41's stacking list to: notification deck, camera feed, alarm alert, DLNA cast, Plex cast, Live TV.

- [ ] **Step 3: Update the spec.** Set **Status** to approved, add the "dismissed tags are only remembered when the card has a `timeout`" rule to the Payload section, and add the camera and Protect screens to Touch points.

- [ ] **Step 4: Run the full checks**

Run: `flutter analyze`
Expected: `No issues found!`

Run: `flutter test`
Expected: all tests pass.

- [ ] **Step 5: Commit and push for hardware testing**

```bash
git add docs/wiki/Notifications.md CLAUDE.md docs/specs/2026-10-30-notification-images-design.md docs/plans/2026-10-30-notification-images.md
git commit -m "docs(notifications): document pictures, tags and camera cards"
git push origin -u task/notification-images
```

The owner then runs the spec's checks on the kitchen Hearth. Do not open a PR or merge until asked.
