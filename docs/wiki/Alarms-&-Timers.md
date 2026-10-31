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
| **Sunrise effect** | Off, or a **Duration** of 5–30 min. Off by default. |
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

> **Not wired up yet:** the **Sunrise effect** is saved with the alarm but doesn't run.

![The alarm editor with time, repeat days, sunrise, and sound](images/alarm-editor.png)
*📷 Planned screenshot — the alarm editor. See [[SHOTLIST]].*

Scripts can also list, create, update, and delete alarms through `/api/alarms` with the
portal's [[API key|The Web Portal]].

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

## Troubleshooting

- **Sunrise did nothing** — the sunrise effect isn't wired up yet (see above).
- **Alarm didn't make a sound** — on the Pi, check the system volume (Menu 2 /
  **[[Navigation & Gestures]]**). On Android, check the tablet's alarm volume in its settings.
- **Timer didn't beep** — check the system volume (Menu 2 / **[[Navigation & Gestures]]**). On
  Android, that's the media volume.
