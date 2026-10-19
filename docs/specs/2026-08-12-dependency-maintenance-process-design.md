# Dependency Maintenance Process Design

**Status:** Proposed
**Date:** 2026-08-12
**Goal:** Keep Hearth's third-party dependencies continuously current so that staying up to date is a background process measured in minutes per month, rather than a multi-day "catch-up" project each time drift becomes painful.

## Why now

An inventory on 2026-08-12 found drift concentrated in the places nothing was watching:

- **37 packages** upgradable but pinned older in `pubspec.lock` — not blocked by constraints, just never refreshed.
- **3 major versions** behind: `flutter_riverpod` 2.6.1 → 3.4.2, `media_kit_video` 1.3.1 → 2.0.1, `bonsoir` 6.0.2 → 7.1.5.
- **1 dead dependency**: `intl` ^0.19.0 is declared but has zero references in `lib/` or `test/`.
- **GitHub Actions 3 majors behind**: `checkout@v4` → v7, `upload-artifact@v4` → v7, `download-artifact@v4` → v8, `action-gh-release@v2` → v3.
- **A three-way Flutter SDK split**: dev machine 3.41.6, desktop CI 3.44.9, Pi CI 3.38.0.

By contrast, the parts under an explicit written policy were clean. Both forks are **zero commits behind** their upstreams — `flutter-pi-hearth` carries 37 Hearth commits on top of `ardera/flutter-pi@f0b3330`, and the GStreamer plugin fork carries 3 on top of `ardera/flutter_packages@68123c2`. The `UPSTREAM_PIN` discipline from the [flutter-pi fork design](2026-05-08-flutter-pi-fork-and-mirror-design.md) worked.

The lesson: drift accumulates precisely where no process exists. This design extends coverage to everything else.

## Non-goals

- **Not** the three major-version migrations. Riverpod 2→3 touches 126 files and is its own project. This design makes that debt *visible and tracked*, not resolved.
- **Not** replacing manual device testing. No automation here proves Hearth renders correctly on the Pi.

## Architecture

Three watchers, each paired with the verification its subject actually admits:

| Watcher | Host | Schedule | Covers | Outcome |
|---|---|---|---|---|
| **Renovate** | Gitea Actions | `@weekly` | pub packages, Flutter SDK pin, `flutterpi_tool`, Action versions, git-ref deps | PR, automerged if eligible |
| **Upstream-drift check** | Gitea Actions | `@weekly` | fork ↔ upstream distance | Gitea issue |
| **Pi bundle build** | GitHub Actions | `@weekly` | arm64 cross-compilation still succeeds | Workflow failure |

### Why Renovate, not Dependabot

Dependabot's `pub` support has been **beta since April 2022**, still does not support security updates for pub, and has open defects where it rewrites `pubspec.lock` Flutter constraints ([dependabot-core#13461](https://github.com/dependabot/dependabot-core/issues/13461)). It also cannot watch the Flutter SDK pin, and it only runs on GitHub — which is Hearth's passive mirror, not where PRs are reviewed.

Renovate has a first-class `pub` manager, dedicated `flutter-version` and `dart-version` datasources, native Gitea platform support, and `customManagers` for arbitrary version strings. It runs where the review happens.

### Why a separate drift check

Renovate tracks *this repo's dependency on* a fork. It has no concept of how far that fork has diverged from *its own* upstream — no dependency-update tool does, because it isn't a dependency relationship. Detecting it is one command, already validated during the inventory:

```bash
git log --oneline up/master ^fork/hearth | wc -l
```

### Why a scheduled Pi build

Desktop CI runs `flutter analyze && flutter test`. That is a real signal — 98 test files, 15k LOC against 42.8k LOC of `lib` — but it is entirely Dart-level. It never invokes `flutterpi_tool`, never cross-compiles for arm64, and never links GStreamer. A weekly bundle build closes the most common gap: a dependency that no longer builds for the Pi. It surfaces within seven days instead of at release time.

It cannot catch runtime rendering regressions. Those remain a manual device test, per the existing test-bundle workflow.

## Renovate configuration

**Hosting.** The `renovate/renovate` container in a scheduled Gitea Actions workflow in this repo. Gitea Actions supports `schedule` cron including `@weekly`. No standalone service to maintain.

**Config-time check:** platform-native automerge requires Gitea ≥ 1.24. Below that, set `platformAutomerge: false` and Renovate merges the PR itself once CI is green — functionally equivalent.

### Managers

| Manager | Target | Datasource |
|---|---|---|
| `pub` (native) | `pubspec.yaml` hosted dependencies | `dart` |
| `github-actions` (native) | `.github/workflows/` **and** `.gitea/workflows/` via extended `managerFilePatterns` | `github-tags` |
| custom regex | `flutter-version: 'x.y.z'` (4 files) | `flutter-version` |
| custom regex | `dart pub global activate flutterpi_tool x.y.z` | `dart` |
| custom regex | `ref: vX.Y.Z` for `sendspin_dart` | `github-tags` |
| custom regex | `ref: vX.Y.Z` for the GStreamer plugin fork | `github-tags` |
| custom regex | pinned flutter-pi tag in `scripts/setup-pi.sh` | `github-tags` |

All three git-ref dependencies must be pinned to **tags**, not branches or SHAs. `github-tags` needs a tag to compare against, and a branch pin is exactly the floating reference this design exists to eliminate.

Extending the `github-actions` manager to `.gitea/workflows/` is load-bearing. The two workflow directories are maintained as deliberate pairs; without it the Gitea copies would rot while the GitHub ones stayed current — reintroducing asymmetric drift inside the very system meant to prevent it.

### Grouping

- All non-major pub updates → **one** grouped weekly PR. One CI run, one merge, one log entry.
- `lockFileMaintenance: enabled`, weekly. This is the setting that addresses the observed state directly: the 37 stale transitives are not constraint-blocked, the lockfile simply pins older. Only lockfile maintenance clears them, and without it they drift straight back.
- Action bumps → their own group.
- Each major → its own PR, never grouped, never automerged.
- `dependencyDashboard: true` → a standing Gitea issue listing everything pending. This is where major-version debt lives as visible, tracked work.

### Automerge policy

| Category | Patch / Minor | Major |
|---|---|---|
| pub packages (incl. `media_kit*`, `video_player*`) | **Automerge on green** | Review |
| GitHub / Gitea Actions | **Automerge on green** | Review |
| Flutter SDK pin | **Review** | Review |
| `flutterpi_tool` | **Review** | Review |
| Fork tags (`flutter-pi-hearth`, plugin fork) | **Review** | Review |
| Android Gradle deps, Gradle wrapper | **Review** | Review |

**Android carve-out (added 2026-10-19).** PR CI does not build the APK, so a green check says nothing about an Android Gradle bump; `flutter build apk --debug` is the check. The Kotlin Gradle plugins and libraries are one `kotlin` group, majors included — the one exception to "each major its own PR" — because split bumps conflicted on adjacent lines and left `main` on mixed Kotlin versions (#300, #301).

**Rationale for the toolchain carve-out.** Package automerge is safe because Hearth's customizations are small and its API surfaces are narrow. That reasoning does not transfer to the Flutter SDK, because the risk there is not a function of how much Hearth has customized — it is a third-party release-cadence coupling. `flutterpi_tool` can only build a Flutter version once ardera publishes matching arm64 engine binaries, and that lags:

| Flutter minor | Released | flutterpi_tool support | Lag |
|---|---|---|---|
| 3.38.x | Dec 2025 | 0.10.0 — 2025-12-10 | days |
| 3.41.x | Mar 2026 | 0.11.0 — 2026-04-19 | ~4 weeks |
| 3.44.x | 2026-05-18 | 0.12.0 — 2026-07-22 | **~9 weeks** |

Automerging a Flutter minor on release day would break the Pi build and leave it broken until ardera catches up — potentially two months — while desktop CI stayed green throughout, because it never touches flutter-pi.

The correct update order is therefore inverted from the usual: **`flutterpi_tool` is the leading indicator, Flutter is the lagging one.** Bump `flutterpi_tool` first; its release notes state which Flutter versions it unlocked; then bump Flutter to that. Renovate cannot express this ordering, which is why it needs a human.

Cost: Flutter ships roughly 4 minors/year and `flutterpi_tool` released 4 times in the last 8 months — about **6–8 review events per year**, each a few minutes.

## Structural changes

Two changes convert hidden drift into tracked drift. Both are prerequisites for the automation being tractable.

### 1. Unify the Flutter pin, then delete the SDK-constraint rewrite

There are four Flutter pins but only two logical values (3.44.9 desktop, 3.38.0 Pi), each duplicated across the workflow pairs. Renovate keys updates on depName + current value, so while those values differ it produces two competing update branches indefinitely.

`flutterpi_tool` 0.12.0 supports Flutter 3.44.x — exactly what desktop CI already pins. Moving the Pi to 3.44.9 collapses all four pins into one tracked dependency.

That in turn makes [`scripts/prepare-pi-build.sh`](../../scripts/prepare-pi-build.sh)'s SDK rewrite unnecessary:

```bash
sed -i 's/sdk: ^3\.[0-9]*\.[0-9]*/sdk: ^3.7.0/' "$PUBSPEC"
```

This line exists only to bridge the version split. It should be **deleted**, not merely left unused — it silently masks SDK incompatibility rather than failing, which is the opposite of what this design is for. With both lanes on 3.44.9, pubspec's `sdk: ^3.11.4` is satisfied directly.

### 2. Pin the flutter-pi clone to a tag

[`scripts/setup-pi.sh`](../../scripts/setup-pi.sh) clones the fork with `--depth 1 -b hearth`, floating on branch head. Two Pis provisioned a week apart run different binaries with no record of which.

This is the same defect `UPSTREAM_PIN` was introduced to fix one level up. The [fork design](2026-05-08-flutter-pi-fork-and-mirror-design.md) states the reasoning explicitly: *"Two fresh installs a week apart could produce different binaries with no record of which upstream commit was in use."* `UPSTREAM_PIN` closed the fork→upstream gap; the Pi→fork gap is still open.

Fix: tag the fork (`v1.0.0`, incrementing per merged change), pin `setup-pi.sh` to the tag, and let Renovate bump it like any other dependency — under review, per the table above.

## Upstream-drift check

`.gitea/workflows/upstream-drift.yml`, weekly plus `workflow_dispatch`. For each fork:

1. Fetch upstream and fork.
2. Read `UPSTREAM_PIN` from the fork.
3. Compare against upstream HEAD; count commits between.
4. If non-zero, open or update a Gitea issue titled `Upstream drift detected`, listing the commit subjects. The title is a fixed string rather than embedding the fork name or count so the workflow can find and update the same issue on subsequent runs instead of opening duplicates.

Comparing against `UPSTREAM_PIN` rather than raw branch distance keeps the check consistent with the fork's existing rebase procedure, which is already documented in the fork design doc.

Tracked pairs:

| Fork | Upstream |
|---|---|
| `chrisuthe/flutter-pi-hearth` @ `hearth` | `ardera/flutter-pi` @ `master` |
| `chrisuthe/flutterpi_gstreamer_video_player-hearth` | `ardera/flutter_packages` @ `main` |

`sendspin_dart` is not a fork — it is a first-party library — and is covered by Renovate's tag tracking instead.

## Pi bundle safety net

Add a `schedule: '@weekly'` trigger to `.github/workflows/build-pi-image.yml`. No other change: the `release` job is already gated on `if: startsWith(github.ref, 'refs/tags/v')`, so a scheduled run performs only `build-bundle` and publishes nothing.

Pi image builds run on GitHub because Gitea cannot build branches.

## Day one: clean-slate PR

Renovate starting against the current baseline would automerge the entire backlog in one run. Instead, one reviewed PR first, verified once on a device:

1. Tag the GStreamer plugin fork at `main` (the PR that the pinned branch was waiting on has merged — `d65b2b87`), then retarget `pubspec.yaml` from branch `chrisuthe/feat/webview-init-script` to that tag.
2. Remove the unused `intl` dependency.
3. `flutter pub upgrade` — 37 package bumps, no constraint changes.
4. GitHub + Gitea Actions to current majors.
5. Pi lane to `flutterpi_tool` 0.12.0 and Flutter 3.44.9; delete the SDK-constraint `sed`.
6. Tag `flutter-pi-hearth`; pin `setup-pi.sh` to the tag.

Then enable Renovate against a current baseline, so its first automerge is an ordinary small one.

**Deferred as tracked debt** on the Dependency Dashboard: `flutter_riverpod` 2→3, `media_kit_video` 1→2, `bonsoir` 6→7.

Note `video_player` is held at 2.11.1 (latest 2.14.0) by the GStreamer plugin fork's own constraint at 0.2.0. Unblocking it requires a fork change and is out of scope here.

## Verification

Success criteria, each independently checkable:

1. `flutter pub outdated` reports no upgradable-but-locked packages after the clean-slate PR.
2. All four `flutter-version` pins read `3.44.9`.
3. `grep 'sdk: \^3\.7\.0' scripts/prepare-pi-build.sh` returns nothing.
4. `scripts/setup-pi.sh` clones a tag, not a branch.
5. A Pi image build succeeds on Flutter 3.44.9 **and** the resulting bundle runs on a device — video playback, webviews, and HDMI mirror all exercised.
6. Renovate's first scheduled run opens a Dependency Dashboard issue listing the 3 deferred majors.
7. A deliberately stale test branch causes the drift check to open an issue.
8. A minor package bump automerges without intervention; a Flutter bump opens a PR and does *not* automerge.

## Risks

- **Automerged package regression on-device.** Accepted deliberately: desktop CI cannot see Pi rendering. Mitigated by the weekly bundle build (catches build breakage, not runtime) and by OTA rollback via `/etc/hearth-version.prev`.
- **Renovate PR volume during the first weeks.** Mitigated by grouping, `prConcurrentLimit`, and the clean-slate PR landing first.
- **Gitea < 1.24** disables platform-native automerge. Fallback is Renovate-side merge; behaviour is unchanged.
- **`ardera/flutter-pi` upstream is quiet** (last commit 2026-01-31). The drift check may report zero for long stretches. That is a correct result, not a broken check.
