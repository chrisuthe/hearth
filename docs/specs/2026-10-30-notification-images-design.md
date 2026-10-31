# Notification images and camera cards

**Date:** 2026-10-30
**Status:** Approved

## Why

When someone walks up to a doorbell camera, the kitchen Hearth should show who
it is, keep that picture current, and open the live feed on a tap. Today a
notification card is text only.

The picture comes from Home Assistant, attached to the notification. That makes
photo notifications a general feature of the ingest payload rather than a camera
feature: any automation can attach any picture, and Hearth needs no knowledge of
which NVR produced it. Home Assistant decides when a person counts (zones, quiet
hours, which cameras). Hearth only displays what it is sent.

## Goals

- A notification may carry a picture, over both MQTT and `POST /api/notify`.
- The picture can refresh in place while the card is up.
- A card may name a Frigate camera. Tapping that card opens the live feed full
  screen, and tapping again returns to whatever was showing.
- An automation can keep one card per camera up for as long as a person is
  detected, then close it.

## Non-goals

- Video inside the card. The card shows stills, and the feed is full screen.
- Live feeds through Home Assistant streams, or from UniFi Protect. `camera` is
  a Frigate camera name only. Both could be added later as new fields.
- Hearth generating detections. `FrigateService.eventStream` has no listeners
  today, and this work does not change that.
- Hearth settings for any of this. There is no new plugin or config field.
- Keeping cards across a restart. The deck stays in memory.
- The Android chime, which is a separate existing gap.

## Must not happen

- Hearth's HA token reaching any host other than the configured HA URL.
- A card polling for a picture forever because a close message was lost.
- A card that loses its picture becoming unusable. It falls back to text.
- A repeat detection stacking a second card or chiming again.
- Two RTSP decoders running at once. `CamerasScreen` records why this matters:
  a stalled decoder can wedge flutter-pi's raster thread.

## Payload

New optional fields on the shared ingest schema. Existing payloads behave exactly
as they do today.

| Field | Values | Effect |
| --- | --- | --- |
| `image` | string | Picture for the card. See **Fetching the picture**. |
| `image_refresh` | seconds, number | Re-fetch `image` at this interval. Omitted means fetch once. Values under 1 are treated as 1. |
| `camera` | string | Frigate camera name. Makes the card tappable, opening that camera's feed. |
| `tag` | string | Stable identity. Sending the same `tag` again updates the existing card. |
| `clear` | `true` | With `tag`: close that card. Idempotent, and no title or message is needed. |
| `timeout` | seconds, number | Close the card this long after its last update. Applies to any card and takes precedence over `sticky`. |

A card with `image_refresh` and no `timeout` gets a 10-minute timeout.

While a person is detected, the automation re-sends the same payload as a heartbeat.
Each one restarts `timeout`, so the card has no time limit while the sensor is on, and
it still closes if the heartbeats and the `clear` are both lost.

If the user dismisses a tagged card with ✕ or a swipe, Hearth remembers that tag and
ignores further updates for it, so a heartbeat cannot bring the card back. Hearth
forgets the tag when a `clear` arrives, or when `timeout` passes with no update. The
next message for that tag is then a new arrival, with a new card and a chime. A card
that closes by `clear` or `timeout` leaves nothing to remember, and neither does a
dismissed card with no `timeout`, because nothing would ever end the memory and an
automation that never sends `clear` would be silenced until a restart. The memory is
not persisted, so a heartbeat after a Hearth restart shows the card again.

`clear` without a `tag` is rejected like an empty payload: a `400` over HTTP and a
logged warning over MQTT.

Example, sent by a Home Assistant automation:

```json
{"tag": "front_door",
 "title": "Person Detected at Front Door",
 "image": "/api/camera_proxy/camera.front_door",
 "image_refresh": 3,
 "camera": "front_door",
 "source": "frigate",
 "timeout": 180}
```

```json
{"tag": "front_door", "clear": true}
```

The title is whatever Home Assistant sends. Hearth does no templating.

### Reference automation

The wiki documents this shape. Entity IDs are placeholders, since the Frigate
integration's sensor names were not checked for this design.

```yaml
alias: Doorbell person → kitchen Hearth
mode: queued
triggers:
  - trigger: state
    entity_id: binary_sensor.REPLACE_front_door_person
    to: "on"
    id: seen
  - trigger: state
    entity_id: binary_sensor.REPLACE_front_door_person
    to: "off"
    for: "00:00:30"
    id: gone
  - trigger: time_pattern
    minutes: "/1"
    id: heartbeat
conditions:
  - condition: template
    value_template: >-
      {{ trigger.id != 'heartbeat'
         or is_state('binary_sensor.REPLACE_front_door_person', 'on') }}
actions:
  - action: mqtt.publish
    data:
      topic: "hearth/REPLACE_DEVICE_ID/notify"
      payload: >-
        {% if trigger.id == 'gone' %}
        {{ {"tag": "front_door", "clear": true} | to_json }}
        {% else %}
        {{ {"tag": "front_door",
            "title": "Person Detected at Front Door",
            "image": "/api/camera_proxy/camera.front_door",
            "image_refresh": 3,
            "camera": "front_door",
            "source": "frigate",
            "timeout": 180} | to_json }}
        {% endif %}
```

## Behaviour

### Decided with the owner

- **Title:** "Person Detected at <camera name>", sent by the automation.
- **Layout:** with a picture, a large picture sits above the text in a tall,
  centred card (layout B in the mockups). Without one, the card looks as it does
  today.
- **Picture updates:** about every 3 seconds in the reference automation. Hearth
  has to request each frame, so this is polling. It stops when the card goes away.
- **Tap:** the card's latest picture fills the screen immediately, and the live feed
  takes over as soon as it is playing. Tapping again returns to what was showing. ✕
  and Mute keep their own jobs.
- **No background video:** the feed starts on the tap, never when a notification
  arrives.
- **Feed source:** Frigate RTSP, the same way the Cameras screen plays it.
- **Lifetime:** the card stays for as long as a person is detected, with no time
  limit, and closes about 30 seconds after they are gone. The ✕ and swipe-up still
  dismiss it sooner, and it stays dismissed for that visit.
- **Feed limit:** the feed returns to the previous screen after 5 minutes, so it
  cannot run unattended on the display. Closing the card does not close the feed.
- **Repeat detections:** the same camera updates its one card with no second chime.
  Two cameras get two cards.
- **Sound:** the Soft Ping plays once on arrival. Night mode still silences it.
- **Failures:** a failed refresh keeps the last good picture. If no picture ever
  loads, the card is text only. If the feed will not open, a short toast appears
  and the card stays.

### Calls made by the author

- **`clear` plus `timeout`, instead of timeout alone.** A timeout-only design
  would let a late "person gone" update recreate a card the user just dismissed.
  `clear` cannot do that, and `timeout` covers the case where `clear` is lost.
- **A one-minute heartbeat with a three-minute `timeout`** in the reference
  automation, so one or two lost messages do not close the card.
- **What counts as a new visit.** The sensor going off and on again within 30 seconds
  sends no `clear`, so a dismissed card stays dismissed. Once the person has been gone
  long enough for `clear` to be sent, the next detection is a new card with a chime.
- **The card and the feed run independently while the feed is open.** The card's
  `timeout`, `clear` and heartbeats carry on behind the feed. If the card has gone by
  the time the feed closes, the user returns to the previous screen without it.
- **Same-`tag` updates are in place.** The card keeps its position and its mute
  state, plays no entrance animation, and restarts its timeout. Its timestamp does
  not change.
- **A same-`tag` update replaces the card's content.** Fields are not merged, so an
  update that omits `image` or `camera` removes it, and an update still needs a title
  or message. Automations send the full payload each time, as the reference does.
- **The feed sits directly above the notification deck** and below the alarm and
  cast overlays, so an alarm still wins. A new card arriving during the feed chimes
  but stays hidden until the feed closes.
- **A card's polling pauses while the feed is open**, to spare the Pi.
- **Tap target:** the whole card, apart from its buttons. A card with no `camera`
  does nothing on tap, and shows no tap hint.
- **The tag pill** reads "Tap for live view" when the card has a `camera`.
  Cards with a `timeout` show no countdown bar.

## Fetching the picture

`image` resolves as follows:

| `image` value | Fetched from | Token sent |
| --- | --- | --- |
| Starts with `/` | `haUrl` + path | Yes, as `Authorization: Bearer` |
| Absolute URL with the same origin as `haUrl` | that URL | Yes |
| Other `http` or `https` URL | that URL | No |
| Anything else | not fetched, so the card is text only | No |

An HA-relative `image` with no HA URL or token configured is also text only.

Requests must not follow redirects when the token is attached, so a redirect cannot
carry it to another host. Fetches need a timeout and a response size cap, and must
not overlap for one card. These details are left to the builder.

**Verified:** `CameraImageView` in Home Assistant Core serves
`/api/camera_proxy/{entity_id}`, and accepts an authenticated request
(`homeassistant/components/camera/__init__.py`, lines 841-889).

**Not verified:** how quickly a given camera's proxied still changes between
requests. That depends on the camera integration, so check it on the real hardware.

## Live feed

Reuse what `CamerasScreen` does: `HearthVideoPlayer.create()`, then
`play(FrigateCamera.fromEntry(name, frigateUrl).rtspUrl)`, with the idle controller
suppressed while it is open.

The card builds the URL from the name rather than requiring the camera to be in
`FrigateService.cameras`, since that list loads asynchronously. With no `frigateUrl`
configured, a tap shows the failure toast.

The overlay takes the card's latest frame when it opens and shows it, scaled to fit,
until video is playing, as `CamerasScreen` does with its snapshot tile. It keeps its
own copy of the frame, so the card closing does not blank it. A card with no frame
yet opens on a plain dark screen until video starts.

The feed closes on a tap, on the stall watchdog, or after 5 minutes, whichever comes
first. It releases the player and unsuppresses the idle controller each way.

The feed is a new overlay in HubShell's full-screen layer, following the existing
pattern: its own `ConsumerWidget`, `SizedBox.shrink()` when closed, and an `onWake`
callback.

**Left to the builder:** whether to extract the expanded view from `CamerasScreen`
or write a smaller one. The stall watchdog (`getCameraFps`) should apply either way.
Also how the "one decoder at a time" rule is enforced when a feed opens while
`CamerasScreen` is expanded, or a cast starts while the feed is open.

## Layout

Layouts must hold at 1184x864, 864x1184 and 800x1280 (`test/portrait/`).

In landscape, the card with a picture is centred and narrower than the full-width
deck, at about 56% of the canvas width. In portrait, and on canvases narrower than
1000 such as half of a split screen, it uses the full width. The deck already scrolls
once it is taller than the screen.

From top to bottom, the card has:

1. The picture, running edge to edge with the card's top corners, with a play icon
   centred on it when the card has a `camera`.
2. The existing meta row: source chip, priority, time and ✕.
3. The title and body.
4. The existing chime row, with Mute and the tag pill.

The left accent rail runs the full height of the card, over the picture.

Do not assume 16:9: doorbells are often 4:3 or taller, and cropping could cut off a
face. The whole frame must stay visible. The builder chooses how to bound the height
and whether to reserve the picture's space while the first frame loads. The picture
must not push the card off screen.

## Touch points

Expected, not exhaustive:

- `lib/models/hearth_notification.dart`: new fields and parsing, one normalize path
  for MQTT and HTTP, and removal of the "camera fields intentionally absent" comment.
- `lib/services/notification_service.dart`: in-place update, clear, timeout.
- `lib/services/mqtt_service.dart` and `lib/services/local_api_server.dart`: handle
  `clear` and update the schema comments.
- `lib/widgets/notification_card.dart` and `notification_deck_overlay.dart`: picture,
  tap, pill, centred width, and removal of the "camera row deferred" comment.
- `lib/app/hub_shell.dart`: the new overlay.
- `lib/modules/cameras/cameras_screen.dart` and `lib/modules/protect/protect_screen.dart`:
  collapse an expanded camera when a feed opens.
- `docs/wiki/Notifications.md` and `CLAUDE.md`: payload docs, the reference automation
  and the overlay stacking list.

## How we will know it works

Automated:

- Parsing of each new field, including `clear` with and without `tag`.
- Service: same-`tag` update keeps position with no chime, `clear` is idempotent,
  `timeout` closes the card and restarts on update, and the 10-minute default applies.
- Dismissed tags: heartbeats are ignored after a dismiss with no chime, and the tag is
  forgotten on `clear` and on `timeout`, so the next message is a new card.
- Feed: shows the card's latest frame before video plays and keeps it if the card
  closes, closes on tap and at 5 minutes, stays open when its card closes, and releases
  the player and idle suppression each way. No player exists until the tap.
- `image` resolution, especially that the token never goes to another origin.
- Card widget: picture shown, refresh replaces it, a failed refresh keeps the last
  frame, no frame falls back to text, tap fires only with `camera`, and polling stops
  on dismiss.
- A camera card added to `test/portrait/overlays_portrait_test.dart` at all three sizes.
- Existing notification tests still pass unchanged.

On the kitchen Hearth, by the owner:

- A person at the door brings up the card, and the picture changes while they stand there.
- Tapping opens the live feed, and tapping again returns to the previous screen.
- A dismissed card stays gone while the person is still there.
- The card closes about 30 seconds after the person leaves.
- Night mode still silences the chime.
