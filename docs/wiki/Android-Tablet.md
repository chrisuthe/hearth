# Android Tablet

> **Experimental.** The Android build runs on wall-mounted tablets and has been tested on
> one tablet so far. Some features do nothing yet — see [what works](#what-works) below
> before you rely on it.

Hearth runs on an **ARM Android tablet, Android 10 or later**: arm64, or 32-bit armv7 (untested). It installs as an ordinary
app, offers itself as the tablet's **Home app** so it starts on boot, runs fullscreen, and
updates itself from new releases.

## Install

1. On the tablet, download `hearth-android-<version>.apk` from the
   [latest release](https://github.com/chrisuthe/Hearth-Home/releases/latest).
2. Open the downloaded file. Android asks whether to allow installs from that source
   (your browser or file manager) — allow it, then tap **Install**.
3. Open Hearth. The first run shows the setup wizard; its WiFi step lists no networks on
   Android, so tap **Skip** — the tablet uses its own WiFi connection.

## Make Hearth the Home app

Hearth declares itself a Home app (launcher), so Android lists it next to the tablet's own
launcher. Choose it under **Settings → Apps → Default apps → Home app** (the exact path
varies by manufacturer). The tablet then boots straight into Hearth and the Home button
returns to it.

Hearth runs fullscreen with the status bar and navigation hidden. A swipe in from the edge
still shows them briefly, and the notification shade is still reachable — Hearth doesn't
lock the tablet down.

**Keep the screen on.** Hearth doesn't stop the tablet from sleeping yet. Set the tablet's
**screen timeout** to its longest value, or turn on **Stay awake** (while charging) in
Android's developer options, so the kiosk stays visible and connected.

## Open the web portal

On any device on the same network, open:

```
http://<tablet-ip>:8090
```

and enter the PIN shown on the tablet. Find the tablet's IP address in Android's WiFi
settings (tap the connected network), or in Hearth's **[[Network|Network & System]]** panel.
`hearth.local` is the Pi's name — it doesn't point at a tablet.

From there, set up your integrations exactly as on a Pi — see **[[The Web Portal]]** and
the [[Installation]] page's *Set up your integrations* step.

## Updates

Hearth updates itself from the `hearth-android-*.apk` attached to each release. The first
time it installs an update it needs permission to **install unknown apps** — Hearth opens
that Android settings page for you; turn it on for Hearth. After that, **Android shows its
own confirmation for every update** ("Do you want to update this app?"); tap **Update**.
Hearth restarts on the new version with your settings intact.

See **[[Updating]]** for automatic checks and the update source.

## Permissions Hearth asks for

- **Microphone** and **notifications** — only when you turn on the
  [[voice satellite|Voice Satellite]]. Android shows an ongoing notification while the
  satellite or [[Sendspin|Multi-Room Audio (Sendspin)]] is running.
- **Install unknown apps** — for self-update (above).
- **Screen capture** — only for the screenshot and recording tools, once per session (see
  [[Network & System]]).

## What works

**Works on the tablet**

- Fullscreen launch as the Home app, swipe screens, edge menus, the on-screen keyboard
- [[Photos & Ambient Display]], [[Weather]], [[Home Assistant Controls]],
  [[Music Assistant]]
- [[Calendar]] and [[Lists & Chores]]
- [[Web Dashboards]] — rendered with Android's own WebView
- [[Voice Satellite]] — the tablet itself becomes a Home Assistant voice satellite
- [[Multi-Room Audio (Sendspin)]] — leave the Server URL blank on Android
- [[Home Assistant Device (MQTT)]] — everything except the Volume entity
- [[Notifications]] — cards and chimes, on the media volume
- [[The Web Portal]], [[screen orientation|Display & Night Mode]] (applies straight away),
  screenshots and screen recording, and self-update

**Not tested on a tablet yet**

- [[Cameras (Frigate)]] and [[Cameras (UniFi Protect)]] live streams
- [[Plex Cast]], [[Live TV (Plex)]] and [[Cast to Hearth (DLNA)]] — phones may not discover
  the tablet as a cast target

**Doesn't work yet**

- **WiFi management** from Hearth — use Android's WiFi settings.
- **Timezone** — Hearth follows the tablet's timezone; set it in Android's settings.
- **Volume over MQTT**, and the portal's logs page (`/logs`).
- **Rollback** — there's no automatic rollback to the previous version on Android.

## Troubleshooting

- **"Install blocked"** — allow installs from the app you opened the APK with (Android asks
  the first time).
- **Hearth isn't on the Home-app list, or the tablet boots to its own launcher** — set Hearth
  as the default Home app (above).
- **Update says it needs permission** — turn on **Install unknown apps** for Hearth, then
  try again.
- **The screen goes dark** — raise the tablet's screen timeout or turn on Stay awake.

See also [[Troubleshooting & FAQ]].
