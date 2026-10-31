# Home Assistant Device (MQTT)

Point Hearth at an MQTT broker and it registers itself in Home Assistant — via
[MQTT discovery](https://www.home-assistant.io/integrations/mqtt/#mqtt-discovery) — as a
single **Hearth** device. Home Assistant then sees what the kiosk is doing (current screen,
now-playing, timers, next alarm) and can control its volume, timers, and alarms — including
by voice, with the custom sentences at the end of this page.

## Before you start

- An MQTT broker reachable by both Home Assistant and Hearth (for example the
  [Mosquitto add-on](https://github.com/home-assistant/addons/tree/master/mosquitto)).
- Home Assistant's [MQTT integration](https://www.home-assistant.io/integrations/mqtt/)
  set up against that broker.

## Connect the broker

Open **MQTT** in the [[web portal|The Web Portal]] or in Settings on the kiosk and enter:

| Field | Example | Notes |
| --- | --- | --- |
| **Broker URL** | `mqtt://192.168.1.x:1883` | Empty = integration off. Also accepts `mqtts://`, host, or host:port. |
| **Username** | *(optional)* | If your broker requires auth. |
| **Password** | *(optional)* | If your broker requires auth. |
| **Discovery Prefix** | `homeassistant` | Match Home Assistant's MQTT discovery prefix; change it only if you customised it in HA. |
| **Device Name** | *(optional)* | The name Home Assistant shows. |

Secure schemes (`mqtts://`, `ssl://`, `tls://`, `wss://`) default to port 8883; plain
`mqtt://` defaults to 1883. The panel shows a live connection status (Connected / Connecting /
Disconnected).

On connect, a Hearth device appears under **Settings → Devices & services → MQTT** in Home
Assistant. With no Device Name set it's called **Hearth (*hostname*)** on a Pi (just
**Hearth** when the hostname is `hearth`) and **Hearth (*tablet model*)** on Android, so
several kiosks on one broker stay apart. Its firmware version is Hearth's installed version,
and its **Visit** link opens the kiosk's web portal.

### Your device ID

The panel also shows the **Device ID**, read-only. Every Hearth topic starts with it:

```
hearth/<device-id>/...
```

so you need it for automations that send commands. It's assigned the first time you set a
broker: a Pi uses its hostname, lowercased with anything other than letters, digits and `_`
replaced (`kitchen-hearth` becomes `kitchen_hearth`); an Android tablet gets a generated ID
such as `hearth_3f9a1c07`. It never changes after that, so the Home Assistant device survives
restarts and renames.

The examples below use `kitchen_hearth` — replace it with yours.

## What Hearth exposes to Home Assistant

| Entity | Type | What it reports / does |
| --- | --- | --- |
| **Current Screen** | sensor | Which screen is showing; `screen_index` attribute. |
| **Now Playing** | sensor | Track title (or `idle`); `artist`, `album`, `player_id` and `playback_state` attributes. |
| **Timer** | sensor | `active` / `fired` / `idle`; `count`, `fired`, `remaining_seconds` and `remaining` attributes for the soonest timer. Updates about every 30 seconds while a timer runs. |
| **Next Alarm** | sensor | The next alarm's time (ISO format, or `none`); `label`, `days_summary` and `sunrise_enabled` attributes. |
| **Screen** | select | The screen showing, by name, **writable**: pick one to switch the kiosk to it. Lists Home, Settings and every screen in the swipe row — see [[Navigation & Gestures]]. |
| **Volume** | number | The kiosk's master output volume (0–100), **writable** from Home Assistant. Pi only — not offered on Android yet. |

Home Assistant names the entities after the device, so with the device called *Hearth* they
are `sensor.hearth_current_screen`, `sensor.hearth_timer`, `number.hearth_volume` and so on.

## Command topics

Hearth listens on these topics. Publish to them from Home Assistant automations or scripts
(the `mqtt.publish` action):

| Topic | Payload | Effect |
| --- | --- | --- |
| `hearth/<device-id>/volume/set` | `45` | Set the master volume to 45% (Pi only). |
| `hearth/<device-id>/timer/start` | `{"duration": 300}` | Start a timer, in seconds (here 5 minutes). |
| `hearth/<device-id>/timer/cancel` | `{}` or `{"timer_id": 3}` | Cancel the newest timer, or a specific one. With no running timer, clears a ringing one. |
| `hearth/<device-id>/alarm/create` | `{"time":"07:30","label":"Wake","days":[1,2,3,4,5]}` | Add an alarm. |
| `hearth/<device-id>/alarm/delete` | `{"alarm_id":"ab12cd"}` | Delete an alarm. |
| `hearth/<device-id>/alarm/snooze` | *(empty)* | Snooze the ringing alarm. |
| `hearth/<device-id>/alarm/dismiss` | *(empty)* | Dismiss the ringing alarm. |
| `hearth/<device-id>/notify` | `{"title":"…","message":"…"}` | Show a notification card — see **[[Notifications]]**. |
| `hearth/<device-id>/screen/set` | `Calendar` or `calendar` | Switch to a screen, by name or ID (what the **Screen** select sends). |

For `alarm/create`: `time` is 24-hour `HH:MM`; `days` uses ISO weekdays (1 = Monday …
7 = Sunday), and an empty or missing list makes a one-time alarm; `label` and
`sunrise_duration` (minutes) are optional, and without `sunrise_duration` the alarm has no
sunrise. Sunrise lights are chosen in the alarm's editor. `alarm/snooze` and `alarm/dismiss` move
the sunrise just as the on-screen buttons do.

A timer started this way behaves like one set on the kiosk — see [[Alarms & Timers]]. (Timers
set through the [[Android voice satellite|Voice Satellite]] belong to Home Assistant and are
cancelled there, not by `timer/cancel` without an ID.)

## Voice control with custom sentences

These let you say *"start a 10 minute timer"* to Home Assistant Assist and have it drive the
kiosk. Two pieces: **custom sentences** that match what you say, and **intent scripts** that
publish the matching command.

### Custom sentences

Save as `config/custom_sentences/en/hearth.yaml` in Home Assistant, then restart Home
Assistant (or reload the Conversation integration):

```yaml
language: "en"
intents:
  HearthStartTimer:
    data:
      - sentences:
          - "(start|set) a {minutes} minute timer"
          - "(start|set) a timer for {minutes} minutes"
  HearthCancelTimer:
    data:
      - sentences:
          - "cancel (the|my) timer"
          - "stop (the|my) timer"
  HearthSetAlarm:
    data:
      - sentences:
          - "set an alarm for {hours}[:| ]{minutes}"
          - "wake me up at {hours}[:| ]{minutes}"
  HearthCancelAlarm:
    data:
      - sentences:
          - "dismiss (the|my) alarm"
          - "turn off (the|my) alarm"
  HearthSnoozeAlarm:
    data:
      - sentences:
          - "snooze (the|my) alarm"
          - "snooze"
lists:
  minutes:
    range:
      from: 0
      to: 180
  hours:
    range:
      from: 0
      to: 23
```

### Intent scripts

Add to `configuration.yaml` (or a package with an `intent_script:` key) and restart Home
Assistant:

```yaml
intent_script:
  HearthStartTimer:
    speech:
      text: "Starting a {{ minutes }} minute timer."
    action:
      - action: mqtt.publish
        data:
          topic: "hearth/kitchen_hearth/timer/start"
          payload: '{"duration": {{ (minutes | int) * 60 }}}'

  HearthCancelTimer:
    speech:
      text: "Timer cancelled."
    action:
      - action: mqtt.publish
        data:
          topic: "hearth/kitchen_hearth/timer/cancel"
          payload: "{}"

  HearthSetAlarm:
    speech:
      text: "Alarm set for {{ '%02d:%02d' | format(hours | int, minutes | int) }}."
    action:
      - action: mqtt.publish
        data:
          topic: "hearth/kitchen_hearth/alarm/create"
          payload: >-
            {"time": "{{ '%02d:%02d' | format(hours | int, minutes | int) }}",
             "label": "Voice alarm"}

  HearthCancelAlarm:
    speech:
      text: "Alarm dismissed."
    action:
      - action: mqtt.publish
        data:
          topic: "hearth/kitchen_hearth/alarm/dismiss"
          payload: ""

  HearthSnoozeAlarm:
    speech:
      text: "Snoozing."
    action:
      - action: mqtt.publish
        data:
          topic: "hearth/kitchen_hearth/alarm/snooze"
          payload: ""
```

Then try *"start a 10 minute timer"*, *"set an alarm for 7:30"* or *"snooze the alarm"*. The
Timer and Next Alarm sensors reflect the result back in Home Assistant.

> On an Android tablet running the built-in [[voice satellite|Voice Satellite]], you don't
> need the timer sentences — Home Assistant's own timer intents already show on the kiosk.

## On Android

MQTT works on a tablet the same way, apart from the **Volume** entity and `volume/set`, which
aren't available yet. The device gets a generated ID and is named after the tablet model.

## Troubleshooting

- **No Hearth device in Home Assistant** — confirm the broker URL is reachable from the kiosk,
  the MQTT integration is set up in Home Assistant, and the **Discovery Prefix** matches
  (`homeassistant` on both sides). See [[Troubleshooting & FAQ]].
- **Commands do nothing** — check the topic uses the **Device ID** from the panel, not the
  device name.
