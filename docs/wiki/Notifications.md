# Notifications

Hearth can show **notification cards** on the kiosk — a doorbell press, a laundry
cycle finishing, an "someone's at the gate" alert. Unlike most of this wiki,
notifications are pushed *into* Hearth (usually from Home Assistant) rather than
configured on the device. Each one surfaces as a card on the kiosk's **bottom
deck**, with an arrival chime and a coloured source chip.

There are exactly **two ways to send** a notification, and both accept the same
payload:

- **MQTT** — publish JSON to the kiosk's `.../notify` topic. Best if you already
  run **[[Home Assistant Device (MQTT)]]** (Hearth needs to be connected to your
  broker for this).
- **HTTP** — `POST` to the kiosk's local API. The fallback when you don't have
  an MQTT broker.

## Send over MQTT

Publish a JSON payload to:

```
hearth/<device-id>/notify
```

`<device-id>` is the kiosk's MQTT device ID (see
[Finding your device ID and address](#finding-your-device-id-and-address) below).
From Home Assistant there are two ways to publish to it.

### 1. The `notify.mqtt` entity (HA 2024.5+)

The simplest path: define an MQTT notify entity whose command topic is Hearth's
notify topic. This sends a **message-only** card (the message becomes the card's
heading; you don't get title/priority/sticky control this way):

```yaml
mqtt:
  - notify:
      name: Hearth
      command_topic: "hearth/<device-id>/notify"
      command_template: '{"message": {{ value | to_json }}}'
```

Then call it like any notifier — e.g. `action: notify.hearth` with
`data.message: "Someone's at the door"`.

### 2. The `mqtt.publish` action (full control)

Publish the JSON yourself when you want a title, priority, or stickiness — e.g.
from an automation:

```yaml
action: mqtt.publish
data:
  topic: "hearth/<device-id>/notify"
  payload: >-
    {"title": "Laundry", "message": "Cycle finished",
     "priority": "info", "sticky": false}
```

## Send over HTTP

If you don't run an MQTT broker, `POST` the same JSON to the kiosk's local API on
port **8090**:

```
POST http://<hearth-ip>:8090/api/notify
```

Like every `/api/*` endpoint, this needs the kiosk's **API key** as a bearer
token (`Authorization: Bearer <key>`). The key is generated on first run — see
*"The API key (for scripts)"* on **[[The Web Portal]]** for how to read it.

A Home Assistant `rest_command` is the tidy way to wire it up:

```yaml
rest_command:
  hearth_notify:
    url: "http://192.168.1.50:8090/api/notify"
    method: POST
    headers:
      authorization: "Bearer YOUR_API_KEY"
      content-type: "application/json"
    payload: '{"title": "{{ title }}", "message": "{{ message }}", "priority": "{{ priority | default(''info'') }}"}'
```

Then call `action: rest_command.hearth_notify` with `data` for `title`,
`message`, and `priority`. A successful post returns `{"status": "ok", ...}`; a
payload with neither a title nor a message is rejected with a `400`.

## Finding your device ID and address

Both paths need to know *which* kiosk to reach:

- **`<device-id>` (for MQTT)** — shown as **Device ID** in the **MQTT** panel,
  on the kiosk and in the portal. On a Pi it's the hostname, lowercased, with
  anything that isn't a letter, digit, or underscore replaced by `_` — a Pi
  named `Hearth-Kitchen` becomes `hearth_kitchen`. On an Android tablet it's a
  generated ID like `hearth_3f9a1c07`. It's fixed the first time you set a broker
  URL, so renaming the device later doesn't change it. All the Hearth
  device's MQTT topics in Home Assistant start with `hearth/<device-id>/`.
- **`<hearth-ip>:8090` (for HTTP)** — the kiosk's IP and portal port. The
  **[[Network|Network & System]]** panel on the kiosk shows the exact address
  (prefer the numeric IP, e.g. `192.168.1.50`, over `hearth.local`).

## Payload fields

Every field is optional **except** that you must send at least one of `title` or
`message`. Both delivery paths share this schema:

| Field | Values / default | What it does |
| --- | --- | --- |
| `title` | string | The card's heading. If omitted, the `message` is promoted to the heading (a message-only card). |
| `message` | string (alias `body`) | The card's body text. One of `title`/`message` is required. |
| `priority` | `alert` \| `info` — default `info` | Sets the accent colour, the chime, and the default stickiness. |
| `sticky` | `true` \| `false` — default: sticky for `alert`, transient for `info` | Whether the card stays until dismissed, or auto-dismisses after 6 seconds. |
| `source` | `frigate` \| `unifi` \| `ha` \| `push` \| `timer` — default `ha` | Drives the source chip. `protect` is accepted for `unifi`, and `home_assistant` for `ha`. An unknown value counts as `ha`. |
| `source_label` | string | Overrides the chip text (default derived from `source`, e.g. `HOME ASST`). |
| `muted` | `true` \| `false` — default `false` | Arrives with no chime. Rarely set — muting is normally a per-card toggle on the kiosk. |
| `image` | path or URL | Picture for the card — see [Pictures and camera cards](#pictures-and-camera-cards). |
| `image_refresh` | seconds | Re-fetch `image` at this interval. Omit it to fetch once. Values under 1 count as 1. |
| `camera` | string | Frigate camera name. Tapping the card opens that camera's live feed. |
| `tag` | string | Stable identity. Sending the same `tag` again updates the existing card instead of adding one. |
| `clear` | `true` | With `tag`: closes that card. No title or message needed. |
| `timeout` | seconds | Closes the card this long after its last update. Takes precedence over `sticky`. A card with `image_refresh` and no `timeout` gets 10 minutes. |

## Pictures and camera cards

Any notification can carry a picture from Home Assistant, which is how a camera
alert shows who's at the door:

```json
{"tag": "front_door",
 "title": "Person Detected at Front Door",
 "image": "/api/camera_proxy/camera.front_door",
 "image_refresh": 3,
 "camera": "front_door",
 "source": "frigate",
 "timeout": 180}
```

**The picture.** A path starting with `/` is read from your Home Assistant, using
the URL and token Hearth already has. So `/api/camera_proxy/<camera entity>` works
for any camera in Home Assistant, whatever NVR is behind it. A full `http` or
`https` URL also works. Hearth only sends your token to your Home Assistant's own
address, so a picture hosted anywhere else must be readable without one. If a
refresh fails, the last good picture stays up. If no picture ever loads, you get a
normal text card.

**The live feed.** `camera` is the name of a camera in **Frigate**, which must be
set up in Hearth. Tapping the card fills the screen with its latest picture straight
away, and live video takes over once it's playing. Tap again to return to what was
showing. The feed also closes by itself after 5 minutes, or if the camera stops
sending video. It keeps running if the card closes behind it.

**One card per visit.** Re-send the same `tag` while the person is there and the
card updates in place, with no second chime. Each message restarts `timeout`, so the
card has no time limit while the messages keep coming, and it still closes if they
stop. Send `{"tag": "...", "clear": true}` when the person has gone.

If you dismiss a tagged card that has a `timeout`, Hearth ignores further updates for
that tag until `clear` arrives or `timeout` passes with no update, so a repeat message
can't bring it back. The next detection after that is a new card with a new chime.
Each update replaces the whole card, so send every field each time.

### Example automation

Replace the sensor, camera and device ID with your own. Your person sensor's name
depends on your camera integration.

```yaml
alias: Doorbell person → kitchen Hearth
mode: queued
triggers:
  - trigger: state
    entity_id: binary_sensor.YOUR_PERSON_SENSOR
    to: "on"
    id: seen
  - trigger: state
    entity_id: binary_sensor.YOUR_PERSON_SENSOR
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
         or is_state('binary_sensor.YOUR_PERSON_SENSOR', 'on') }}
actions:
  - action: mqtt.publish
    data:
      topic: "hearth/<device-id>/notify"
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

The card closes about 30 seconds after the person leaves.

## On the kiosk

When a notification arrives:

- **Bottom deck** — cards stack along the bottom edge of the screen, newest
  nearest your hand.
- **Arrival chime** — an `alert` plays the **Ember Alert** (an urgent triple
  beep); an `info` plays the **Soft Ping** (a single gentle tone).
- **Night mode silences the chime** — while the display is in night mode
  (**[[Display & Night Mode]]**) cards still appear, but arrive silently. A
  `muted` card is likewise silent.
- **Sticky vs transient** — a sticky card stays until you dismiss it; a transient
  card auto-dismisses after **6 seconds**. `alert` defaults to sticky, `info` to
  transient (override with the `sticky` field).
- **Dismiss** — tap a card's **✕**, or swipe it up.
- **Mute** — each card has a **Mute** / **Unmute** button that silences its
  chime.
- **Source chip** — each card shows an uppercase chip for its source:
  `FRIGATE`, `PROTECT`, `HOME ASST`, `PUSH`, or `TIMER` (or your `source_label`).

## Troubleshooting

- **No card appears** — for MQTT, check the topic's `<device-id>` matches the
  **Device ID** in the kiosk's MQTT panel, and that the panel shows Hearth as
  connected; for HTTP,
  check the `<hearth-ip>:8090` address and that the `Authorization: Bearer` key
  is correct (a wrong key returns `401`). Confirm your payload has a `title` or
  `message`.
- **Card appears but no sound** — the kiosk is likely in **night mode** (chimes
  are suppressed), the payload set `muted: true`, or it's an Android tablet
  (below).

## On Android

Cards arrive and behave the same on an [[Android Tablet]], over MQTT or HTTP,
but the **chime doesn't play yet**. Use the tablet's IP address for HTTP —
`hearth.local` doesn't reach a tablet.

See [[Troubleshooting & FAQ]] for more.
