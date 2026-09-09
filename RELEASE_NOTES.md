# Photos Backup 0.4.1 — Smooth activity list

*Version 0.4.1 · build 15 · [compare with 0.4.0](https://github.com/AngrySmoker/PhotosBackup/compare/0.4.0...0.4.1)*

Fixes the app (and sometimes the whole phone) lagging while a large backup
runs. The cause: every upload and hash progress tick republished the queue to
the interface, dozens of times a second per row, so scrolling the Activity
list re-rendered everything each time. Progress now publishes only when the
whole percent actually moves and at most a few times a second per row — the
bars still fill smoothly, phase labels (Preparing → Checking → Uploading →
Finishing → Backed up) still change instantly, and nothing about what gets
backed up, retried, or persisted has changed. 145 offline tests.

# Photos Backup 0.4.0 — Run in Background

*Version 0.4.0 · build 14 · [compare with 0.3.5](https://github.com/AngrySmoker/PhotosBackup/compare/0.3.5...0.4.0)*

Until now, Photos Backup could only move photos while the app was open, or
during the short, unpredictable windows iOS sometimes grants in the
background. **0.4.0 adds a schedulable background runner**: after you leave
the app, it keeps uploading for exactly as long as you asked it to — without
waiting for iOS to decide.

## Highlights

- **New "Run in Background" toggle** — Settings → Backup. Off by default.
- **"Run For" scheduler** — choose how long a background run lasts: 30
  minutes, 1, 2, 3, 4, 6, 8, or 12 hours. Your choice is remembered.
- **Continuous uploads after you leave the app** — the queue keeps exporting,
  hashing, de-duplicating and uploading until it is empty, instead of pausing
  the moment the screen turns off.
- **Stops itself safely** — a run ends the moment the queue is empty, the app
  returns to the foreground, automatic backup becomes unavailable (network
  pause, disconnect, halted queue), or your chosen time runs out. A status
  line in Settings reports what the last run did: "Reached its 2-hour run
  limit", "The queue is empty", "iOS took the audio session away", …
- **Plays nicely with your music** — the runner works by playing an
  inaudible audio track, mixed *under* whatever else is playing, so Music and
  Podcasts keep playing untouched.

## Why this feature exists

iOS never lets an ordinary app run continuously in the background. Photos
Backup already used every sanctioned mechanism — a `BGProcessingTask` for
scheduled processing windows, and an iOS-owned background `URLSession` that
keeps file uploads moving even after the app is suspended. But those windows
are opportunistic (often once or twice a day), which makes a large backup
crawl. This release adds the one remaining option a self-signed app has:
holding an active audio session, which iOS will not suspend.

## How to use it

1. Install this build (it must be **rebuilt and re-installed** — the app's
   background-mode declaration changed).
2. Settings → Backup → turn on **Run in Background**.
3. Pick **Run For** — for example 6 hours before going to bed.
4. Start a backup (or rely on Automatic Backup), then leave the app.
5. iOS shows a Now Playing entry for Photos Backup — that is the runner
   working. Uploads continue with the app off-screen until the queue is empty
   or your chosen time is up.

## When a run stops

| Condition | Result |
| --- | --- |
| Queue is empty | Run ends: "The queue is empty" |
| Chosen time elapsed | Run ends: "Reached its 2-hour run limit" |
| You reopen the app | Runner hands back to normal foreground operation |
| iOS takes the audio session (a call, exclusive audio elsewhere) | Run ends; iOS may still grant a processing window later |
| Wi-Fi lost / Automatic Backup off / account disconnected | Run ends; the durable queue resumes next time anything changes |

## Battery, honesty, and limits

- The runner trades **battery for time**: CPU, radio and the audio pipeline
  stay awake for the whole run. Overnight on a charger is the ideal use; a
  12-hour run on battery is possible but will be noticeable.
- **Do not swipe the app away.** Force-quitting kills everything, including
  this feature — leave the app in the app switcher instead.
- Photos that live in iCloud still wait for the foreground (unchanged from
  0.3.5): background work never spends its window downloading cloud-only
  originals.
- The runner complements, not replaces, iOS's own processing windows. Those
  still run when the runner is off, and long file uploads still continue
  under iOS after suspension either way.
- Keep Background App Refresh enabled for the non-audio mechanisms; the
  audio runner itself does not depend on it.
- The same 0.3.5 disclaimer applies to everything above: this app talks to
  Google's private Photos API and may stop working at any time.

## For developers

- New `App/Sources/BackgroundKeepAlive.swift`:
  - `KeepAliveEngine` protocol so the state machine is testable offline;
  - `SilentAudioKeepAliveEngine` — `AVAudioSession` category `.playback`
    with `.mixWithOthers`, interruption and media-services-reset handling,
    and a RIFF/WAVE silence file generated in code at 1% volume (some iOS
    builds optimise away digital silence);
  - `BackgroundKeepAlive` — `start(duration:)` clamped to 15 minutes–12
    hours, a per-run timeout task, and a published `lastStopReason` for the
    Settings status line.
- `AutomaticBackupCoordinator` begins a keep-alive drain on entering the
  background when the setting is on and work remains; the drain loop gates on
  `isDrainAlive` (`isForeground || backgroundDrainActive`), and every exit
  the loop already honoured — halt, network pause, disconnect, empty queue —
  now also stops the engine.
- `App/Resources/Info.plist` adds `audio` to `UIBackgroundModes` (alongside
  `processing`); `project.yml` bumps to 0.4.0 (build 14).
- 10 new offline tests in
  `Tests/PhotosBackupTests/BackgroundKeepAliveTests.swift` cover the engine
  lifecycle, refused starts, audio loss, the generated WAV format, duration
  clamping, limit labels and preference persistence — 142 tests total.
- Run the suite with:
  `xcodegen generate && xcodebuild -project PhotosBackup.xcodeproj -scheme PhotosBackup -destination 'platform=iOS Simulator,name=<sim>' CODE_SIGNING_ALLOWED=NO test`

---

<details>
<summary>Maintainer notes — publishing this release (not part of the notes)</summary>

Everything above the horizontal rule is the paste-ready body for the GitHub
Release tab.

```sh
git push origin main 0.4.0

Pushing the tag also triggers the Actions workflow (.github/workflows/
build-ipa.yml): a GitHub macOS runner builds the unsigned IPA, attaches it to
this release, and fills the body from this file — the Release tab is complete
without any manual editing. Trigger "Build unsigned IPA" from the Actions tab
for an ad-hoc build of any other commit.
```
</details>

