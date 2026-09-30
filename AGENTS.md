# AGENTS.md — TokDown

One repo, two apps:
- **macOS menu bar meeting recorder** — the root Swift package. Captures system output and microphone together and saves local markdown transcripts.
- **iOS Limitless Pendant companion** — `iOS/`, an XcodeGen project with its own `CLAUDE.md`. It arrived by subtree merge from tokdown-mobile. Nothing is shared between the apps yet; the next step is extracting a shared `Shared/` target (formatter, transcription protocol, calendar and settings cores).

Product constraints (macOS):
- local transcription only; no cloud, no API keys, no third-party dependencies
- raw audio stays in TokDown-owned temporary storage and is permanently deleted (not moved to Trash) after a usable transcript; it is kept in the save folder only when transcription returns nothing usable
- output is plain markdown in a user-selected folder
- three states: `idle -> recording -> transcribing -> idle`
- menu bar only (`LSUIElement`), via `MenuBarExtra` with `.menu` style

## Layout

```text
Package.swift
macOS/
  TokDownApp.swift            app entry, menu bar scene, settings window
  MenuBarCoordinator.swift    state machine, permission gating, orchestration
  MenuBarCoordinator+Messages.swift  pure status-message and naming helpers
  MenuBarViews.swift          menu content and settings UI
  MenuBarIconView.swift       menu bar icon states
  SystemAudioService.swift    Core Audio process tap + level metering
  RecordingService.swift      microphone capture
  AudioMixingService.swift    local system + mic mix before transcription
  TranscriptionService.swift  SpeechTranscriber / SpeechAnalyzer pipeline
  TranscriptFormatter.swift   front matter, title inference, markdown
  StorageService.swift        transcript paths, temporary audio cleanup
  CalendarService.swift       EventKit meetings and access states
  SettingsStore.swift         preferences
  AppModels.swift             data types
  Resources/                  Info.plist, entitlements, TokDownIcon.png (1024px, -> .icns at build)
Tests/                        XCTest + Swift Testing
scripts/
  build-app.sh                build, bundle, sign (dev identity)
  mac-release.sh              Developer ID sign, notarize, staple, zip (copy of the shared ios skill script)
iOS/                          iOS app: App/, Tests/, project.yml (run `xcodegen generate`; .xcodeproj is not tracked)
```

## Commands

```bash
swift test                                  # unit tests
bash scripts/build-app.sh debug && open TokDown.app
pkill -x TokDown
```

Ship a notarized release (needs a `Developer ID Application` identity and a `notary` notarytool profile). Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist` first:

```bash
bash scripts/build-app.sh release
bash scripts/mac-release.sh TokDown.app macOS/Resources/TokDown.entitlements
gh release create vX.Y.Z TokDown.app.zip
```

Then set `version` and the printed `sha256` in `Casks/tokdown.rb` in `SCTY-Inc/homebrew-tap`.

## Implementation notes

Swift 6 and concurrency:
- `@Observable` only. No `ObservableObject`, `@Published`, `@StateObject`, or `@EnvironmentObject`.
- All services are `@MainActor`. A closure created inside a `@MainActor` type inherits MainActor isolation and SIGTRAPs (`dispatch_assert_queue`) when the system calls it off-main. This has crashed Record twice: the Core Audio IO proc (2026-06-03) and the speech authorization callback (2026-09-30). Prefer the SDK's imported `async` API (`AVCaptureDevice.requestAccess`, `EKEventStore.requestFullAccessToEvents`); otherwise mark the closure `@Sendable`. Never `Task { @MainActor in }` inside a completion handler.
- For non-observed properties used in `deinit` of an `@Observable` class, use `@ObservationIgnored` plus `isolated deinit`, not `nonisolated(unsafe)`.

Audio capture:
- System audio uses a **Core Audio process tap** (`AudioHardwareCreateProcessTap` + private aggregate device on the default output), not ScreenCaptureKit. SCK rode a display-bound stream and captured silence with the lid closed; the tap survives lid-close.
- The IO-proc block must be `@convention(block) @Sendable`. It runs on a Core Audio RT thread; `TapWriter` (`@unchecked Sendable`) serializes `AVAudioFile` writes and peak metering with an `NSLock`. Reference: insidegui/AudioCap.
- `SystemAudioService.stopCapture()` is `async throws`: `.noAudioCaptured` when zero frames were written, `.tapCreationFailed` / `.aggregateCreationFailed` / `.writeFailed` on Core Audio errors.
- `MenuBarCoordinator` warns if system audio stays silent past `silenceGraceSeconds` (8).
- Meeting Audio records system and mic tracks in parallel; `AudioMixingService` mixes them into one temporary `.m4a` for transcription. If system capture fails, the mic track is transcribed with an incomplete-capture warning.

Transcription:
- SpeechTranscriber needs no speech-recognition authorization (verified 2026-09-30). Do not reintroduce `SFSpeechRecognizer.requestAuthorization` or `NSSpeechRecognitionUsageDescription`. Only model asset availability is preflighted before recording.
- `SpeechAnalyzer` keep-alive: `_ = analyzer` must come **after** the `for try await` loop. ARC ends lifetime at last use.
- `transcribe()` timeout is `max(300, duration×2 + 60)` seconds (1800 when duration is unreadable), raced in a `withThrowingTaskGroup`; throws `TranscriptionError.timeout`.

Storage, calendar, settings:
- `StorageService` records under a TokDown temporary session folder and writes only `.md` to the selected folder. `loadMeetings()` calls `cleanupTemporaryAudioFiles()`, which deletes only `.m4a` files in TokDown temporary storage.
- Filenames: `YYYY-MM-DD_HH-mm_Title[-2].md`, date-first, collision-safe. `latestTranscriptURL` backs "Open Latest Transcript".
- Calendar needs full access; `.writeOnly` is upgrade-required, not success. `EKEventStore.changedNotification` refreshes meetings only when idle.
- `SettingsStore.init(defaults:)` takes a `UserDefaults` suite; tests use `UserDefaults(suiteName: UUID().uuidString)`.
- TCC permissions depend on code signing. Switching signing identity (dev -> Developer ID) resets grants once.

## Verify

A change is done when `swift test` passes, `build-app.sh debug` produces the app, and the changed workflow works in the running app. TCC, menu bar rendering, and audio capture are runtime-only, so check manually as relevant:
- recording starts and stops; transcript lands in the chosen folder with a meaningful date-first name
- Meeting Audio captures a remote voice (system output) and a local voice (mic), including with headphones
- selected meetings add calendar front matter
- temporary audio is permanently deleted; the transcript folder holds markdown only
- silent system-audio capture fails loudly instead of writing `(No transcript)`
- settings persist across relaunch

Update `README.md` when behavior, install, or permissions change.

## Transcript format contract

Keep stable unless there is a clear product reason; document any change in `README.md`.

```markdown
---
title: "Meeting Title"
source: "calendar_selection"
calendar_provider: "apple_calendar"
audio_source: "system_audio_and_microphone"
recording_started_at: "2026-03-09T14:00:00-04:00"
recording_ended_at: "2026-03-09T14:30:00-04:00"
calendar: "Work"
event_id: "abc123"
event_start: "2026-03-09T14:00:00-04:00"
event_end: "2026-03-09T14:30:00-04:00"
location: "Zoom"
url: "https://zoom.us/j/123"
organizer:
  name: "Jane Doe"
  email: "jane@example.com"
attendees:
  - name: "Jane Doe"
    email: "jane@example.com"
notes: |
  Agenda and invite notes.
---

# Meeting Title

2026-03-09 14:00–14:30

[00:05] First chunk of transcribed text grouped by ~5s windows.

[00:10] Next chunk continues here with natural grouping.
```

Manual recordings omit calendar fields and infer a title from the transcript.
