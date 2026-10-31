# Alarms & Timers

Hearth has two separate time features: **alarms** (scheduled, recurring or one-time) and
**timers** (quick countdowns). Both alert you over whatever screen you're on.

## Alarms

Add and edit alarms in any of three places:

- **Web portal** — open **Alarm Clock** in the [[web portal|The Web Portal]]. It lists your
  alarms with **Edit** and **Delete**, and **+ Add alarm** opens the editor.
- **On-device Settings** — **Settings → Alarm Clock** lists your alarms and has an **Open Alarm
  Editor** button for a new one.
- **The Alarms screen** — an optional screen, not placed anywhere by default. Enable **Alarms**
  in **Screens & Order** (see [[Navigation & Gestures]]); in the swipe row it sits left of
  Home. It shows *"Next alarm in …"*, a switch on each alarm to turn it on or off, tap an alarm
  to edit it (with **Delete**), and **+** to add one.

All three edit the same list. Each alarm has:

| Field | What it does |
| --- | --- |
| **Time** | When the alarm fires (24-hour HH:MM). |
| **Label** | Optional name shown for the alarm. |
| **Repeat** | Day-of-week toggles (M T W T F S S). Leave all off for a **one-time** alarm. |
| **Sunrise effect** | Off, or a **Duration** of 5–30 min and any **Lights** to bring up with it. Off by default. |
| **Sound** | *Gentle Morning* (default), *Birdsong*, *Classic*, or *Bright Day*. |
| **Snooze duration** | 5, 10, 15, or 20 min; default 10. |
| **Volume** | 0–100%; default 70%. |
| **Enabled** | Turn the alarm on or off without deleting it. |

When an alarm fires you get a full-screen alert showing the current time. **Tap anywhere to
snooze**, or tap **Dismiss**. A one-time alarm turns itself off once you dismiss it. Alarms are
saved on the device and survive restarts. The **next** alarm is also published to Home
Assistant if you've set up **[[Home Assistant Device (MQTT)]]**, which can also create, delete,
snooze, and dismiss alarms.

When an alarm fires, its **Sound** loops at its **Volume** until you snooze or dismiss it, and a
snoozed alarm rings again when the snooze time ends. If nobody responds, the sound stops after
30 minutes and the alarm stays on screen. A snooze doesn't survive restarting Hearth. An alarm
rings within a few seconds of its time, and if Hearth was off and comes back more than a minute
late, it waits for the alarm's next time.

If another alarm comes due while one is ringing, it rings as soon as the first is snoozed or
dismissed. If the first has already gone quiet after its 30 minutes, the new alarm takes over and
the first counts as dismissed.

### Sunrise

An alarm with a **Sunrise effect** starts it that many minutes before its time: a 7:00 alarm
with a 15-minute sunrise starts at 6:45. If you save the alarm, or Hearth restarts, partway
through those minutes, the sunrise picks up where it would have been.

**On the screen**, the photos fade down over the first third, then warm through orange to a pale
gold by the time the alarm rings. It's a tint over the photos and can't change the panel's own
brightness. You'll see it on Home and other screens that show the photo behind them. Screens with
a solid background, such as Calendar or Settings, cover it until Hearth goes idle and returns
Home.

**Lights** are optional and chosen per alarm, in the same editor. Only lights that can dim are
offered, because an on/off light would come on fully at the start. Chosen lights start at their
lowest level and reach full when the alarm rings, going from warm (2200K) to cooler white (4000K);
lights without colour control change brightness only. Hearth sends the level every 30 seconds, so
a light you turn off during a sunrise comes back on at the next step. Lights need a connection to
[[Home Assistant|Home Assistant Controls]].

| When you… | Screen | Lights |
| --- | --- | --- |
| **Snooze** | Drops back to dark purple and climbs again until it rings | Drop to 30% warm and climb again until it rings |
| **Dismiss** | Tint ends | Stay as they are |
| Turn off, delete, or move the alarm during a sunrise | Tint ends | Stay as they are |

Lights never turn off by themselves, even if nobody responds to the alarm. Snoozing, dismissing and
the rest work the same from the kiosk, the web portal, or Home Assistant.

![The alarm editor with time, repeat days, sunrise, and sound](images/alarm-editor.png)
*📷 Planned screenshot — the alarm editor. See [[SHOTLIST]].*

Scripts can also list, create, update, and delete alarms through `/api/alarms` with the
portal's [[API key|The Web Portal]]. An alarm created without `sunriseDuration` has no sunrise.

## Timers

Timers are quick countdowns, separate from alarms. Open the timer screen from the **Timer**
tile in **Menu 1** (the default bottom edge-swipe menu — see **[[Navigation & Gestures]]**), or
from the timer pill on Home while a timer runs. Pick a preset (**1**, **5**, **10**, or
**15 min**) or set hours, minutes, and seconds and tap **Start**. Use **+** to add more; several
timers run at once.

While a timer runs, the Menu 1 tile shows the time left (or how many timers are running).
When a timer reaches zero, a **"Time's up"** alert card appears in the
[[notification deck|Notifications]] over any screen, and the Pi plays a looping beep until you
dismiss it — tap the finished timer, or dismiss its card. A running timer can't be cancelled
from the timer screen yet.

Timers are in-the-moment — they aren't saved across restarts the way alarms are. Their state
(active / fired / remaining) is also exposed to Home Assistant via
**[[Home Assistant Device (MQTT)]]**, and timers can be **started or cancelled from Home
Assistant** over MQTT.

## On Android

On an [[Android tablet|Android Tablet]], alarms and timers show the same screens and alerts.
A finished timer rings through the built-in [[voice satellite|Voice Satellite]] when the satellite
is running, and beeps otherwise. Timers you set by voice through that satellite also show on the
timer screen and ring there.

Two different volumes apply. Timer beeps use the tablet's media volume, which Hearth's own slider
controls. Alarm tones use the tablet's **alarm volume**, set in Android's settings, so turning
music down at bedtime can't silence an alarm. Each alarm's **Volume** setting applies on top.

The sunrise tint only shows while Hearth is on screen. If another app is in front, the lights still
ramp and Hearth comes forward when the alarm rings.

## Troubleshooting

- **Sunrise did nothing on screen** — check the alarm has a **Sunrise effect** set, and that you're
  on Home or another screen that shows the photo; solid screens cover the tint.
- **Sunrise lights didn't come on** — check they're ticked on that alarm and that Hearth is connected
  to Home Assistant.
- **A light isn't offered for the sunrise** — it can only turn on and off, or Home Assistant isn't
  reporting it right now.
- **Alarm didn't make a sound** — on the Pi, check the system volume (Menu 2 /
  **[[Navigation & Gestures]]**). On Android, check the tablet's alarm volume in its settings.
- **Timer didn't beep** — check the system volume (Menu 2 / **[[Navigation & Gestures]]**). On
  Android, that's the media volume.
