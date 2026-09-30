# AGENTS.md — TokDown

Scope: this repository

## What this repo is

TokDown is one repository containing a macOS menu bar meeting recorder at the root and an iOS Limitless Pendant companion under `Apps/iOS/`. The macOS app captures system output and microphone audio together for meetings, then saves agent-ready markdown transcripts.

Core product constraints:
- local transcription only
- no external dependencies
- no API keys
- audio files are permanently deleted after transcription
- raw audio stays in TokDown-owned temporary storage, never the user-selected transcript folder
- output is plain markdown in a user-selected folder

## Repo layout

```text
.
├── Package.swift
├── README.md
├── AGENTS.md
├── CLAUDE.md
├── Apps/
│   └── iOS/                 # Limitless Pendant iOS app (XcodeGen project)
├── scripts/
│   └── build-app.sh
├── icon.png
├── Tests/
│   └── TokDownTests/
│       ├── CalendarServiceTests.swift
│       ├── MenuBarCoordinatorTests.swift
│       ├── MenuBarIconPresentationTests.swift
│       ├── RecordingServiceTests.swift
│       ├── SettingsStoreTests.swift
│       ├── StorageServiceTests.swift
│       ├── SystemAudioServiceTests.swift
│       ├── TranscriptFormatterTests.swift
│       └── TranscriptionServiceTests.swift
└── Sources/
    └── TokDown/
        ├── TokDownApp.swift
        ├── MenuBarCoordinator.swift
        ├── MenuBarIconView.swift
        ├── MenuBarViews.swift
        ├── SystemAudioService.swift
        ├── RecordingService.swift
        ├── AudioMixingService.swift
        ├── TranscriptionService.swift
        ├── TranscriptFormatter.swift
        ├── CalendarService.swift
        ├── StorageService.swift
        ├── SettingsStore.swift
        ├── AppModels.swift
        └── Resources/
            ├── Info.plist
            ├── TokDown.entitlements
            ├── TokDownIcon.png
            └── TokDownIcon.svg
```

## Important files

- `Sources/TokDown/TokDownApp.swift` — app entry, menu bar scene, settings window
- `Sources/TokDown/MenuBarCoordinator.swift` — state machine, permission gating, and orchestration
- `Sources/TokDown/MenuBarViews.swift` — menu bar content and settings UI, including latest transcript and audio source selection
- `Sources/TokDown/SystemAudioService.swift` — system audio capture via a Core Audio process tap (+ live level metering)
- `Sources/TokDown/RecordingService.swift` — microphone capture for meetings and microphone-only sessions
- `Sources/TokDown/AudioMixingService.swift` — combines system and microphone tracks locally before transcription
- `Sources/TokDown/TranscriptionService.swift` — Apple SpeechTranscriber pipeline
- `Sources/TokDown/TranscriptFormatter.swift` — front matter, title inference, and markdown rendering
- `Sources/TokDown/StorageService.swift` — transcript paths, deletion, and temporary `.m4a` cleanup on startup
- `Sources/TokDown/CalendarService.swift` — upcoming meetings and calendar permissions
- `scripts/build-app.sh` — build, bundle, sign, and zip release artifact
- `scripts/mac-release.sh` — Developer ID sign, notarize, staple, and zip for distribution (copy of the shared `ios` skill script)

## How to run the project

Build and launch a debug app bundle:

```bash
bash scripts/build-app.sh debug
open TokDown.app
```

Kill the running app:

```bash
pkill -x TokDown
```

Build a release bundle and zip for GitHub Releases:

```bash
bash scripts/build-app.sh release
```

Artifacts:
- `TokDown.app`
- `TokDown.app.zip`

Ship a notarized release (needs a Developer ID identity and a `notary` notarytool profile):

```bash
bash scripts/build-app.sh release
bash scripts/mac-release.sh TokDown.app Sources/TokDown/Resources/TokDown.entitlements
gh release create vX.Y TokDown.app.zip
```

Then set `version` and the printed `sha256` in `Casks/tokdown.rb` in `SCTY-Inc/homebrew-tap`.

## Build, test, and lint commands

There is no lint setup yet, but there is a focused XCTest suite covering transcript formatting, calendar access decisions, coordinator status handling, menu bar icon presentation, storage collision/cleanup behavior, temporary audio cleanup, system-audio rollback cleanup, system-audio zero-capture error reporting, speech-permission mapping, microphone permission-state mapping, and settings persistence.

Use these checks before submitting changes:

```bash
swift test
swift build -c debug
bash scripts/build-app.sh debug
bash scripts/build-app.sh release
```

Manual verification matters for this repo because permissions, menu bar rendering, and TCC behavior are runtime-sensitive.

## Engineering conventions

- Keep the app small and dependency-free.
- Prefer straightforward SwiftUI/AppKit integration over abstraction-heavy design.
- Preserve the three-state flow:
  - `idle -> recording -> transcribing -> idle`
- Keep transcript output as plain markdown.
- Prefer explicit file/service names over generic helpers.
- Keep user-facing behavior local-first and privacy-preserving.
- Update `README.md` when behavior, install steps, branding, or requirements change.
- Update `AGENTS.md` when architecture, workflow, or contributor expectations change.

## PR expectations

A good PR for this repo should:
- stay scoped to a clear user-facing improvement or bug fix
- explain what changed and why
- mention any permission, signing, or macOS-version implications
- include manual verification notes
- avoid unrelated renames or cleanup unless explicitly intended

If the PR changes output format, permissions, packaging, or branding, update docs in the same PR.

## Constraints and do-not rules

Do:
- use `read` before editing files
- use the build script for app bundling/signing
- keep generated transcript output markdown-only
- preserve deletion of audio after transcript generation
- preserve menu bar app behavior (`LSUIElement`)

Do not:
- add cloud transcription or API-key requirements without explicit approval
- add third-party dependencies casually
- keep raw audio files by default
- break system-audio capture to optimize for mic-only workflows

- commit generated app bundles or release zip files to git unless explicitly requested
- use `rm`; use safer alternatives if file removal is needed

## Platform and implementation notes

- Target platform: `macOS 26+`
- Uses `@Observable` (Observation framework) — not `ObservableObject`/`@Published`. Views use `@State`/`@Environment`, not `@StateObject`/`@EnvironmentObject`.
- The app uses Apple’s newer on-device SpeechTranscriber pipeline.
- Speech recognition permission and SpeechTranscriber asset availability are checked before recording starts because the product promise is transcript-first, not raw-audio capture.
- The menu exposes the latest saved transcript directly and does not maintain a transcript database. Audio is normally deleted after transcription, but is **retained** in the save folder when the transcript comes back empty/placeholder, so a silent capture is recoverable.
- System-audio capture uses a **Core Audio process tap** (`AudioHardwareCreateProcessTap` + a private aggregate device anchored to the default output device), not ScreenCaptureKit. The tap anchors to an audio device, so it survives lid-closed / display-off / screen-lock — the failure mode that made the old display-bound SCK path capture silence.
- `SystemAudioService` meters per-buffer peak amplitude on the IO-proc thread; `MenuBarCoordinator` polls `hasCapturedAudibleSignal()` and shows a live warning if a system-audio capture looks silent past an 8s grace.
- Meeting Audio always records system output and microphone in parallel, locally mixes the tracks into one temporary `.m4a`, and transcribes that mix. This records both sides with speakers or headphones. If system capture fails, TokDown transcribes the surviving microphone track and reports that the meeting capture was incomplete.
- Audio capture writes via `AVAudioFile` inside a Core Audio real-time IO proc (`AudioDeviceCreateIOProcIDWithBlock` with a nil queue → CA-owned thread, not main); `TapWriter` (`@unchecked Sendable`) serializes file access and metering with an `NSLock`. The IO-proc block **must** be typed `@convention(block) @Sendable`: it is created inside `@MainActor SystemAudioService.startCapture`, so without `@Sendable` Swift 6 infers MainActor isolation and emits an executor assertion at the block's entry — which traps (`SIGTRAP`/`dispatch_assert_queue`) on the first buffer when CA runs it off-main.
- `SystemAudioService.stopCapture()` is `async throws` — propagates `SystemAudioError.noAudioCaptured` when zero frames were written and `SystemAudioError.writeFailed`/`.tapCreationFailed`/`.aggregateCreationFailed` on Core Audio errors.
- `TranscriptionService.transcribe()` uses a duration-scaled timeout (`max(300, duration×2 + 60)`, or 1800s when duration is unreadable) implemented as a `withThrowingTaskGroup` race; throws `TranscriptionError.timeout` if the pipeline stalls. The old fixed 300s cap false-failed long recordings.
- `MenuBarCoordinator` observes `EKEventStore.changedNotification` to auto-refresh meetings; only acts when `state == .idle` to avoid clobbering recording status messages. `loadMeetings()` also calls `StorageService.cleanupTemporaryAudioFiles` on each invocation to delete any `.m4a` files left behind in TokDown-owned temporary storage.
- `SettingsStore.init(defaults:)` accepts a `UserDefaults` suite for test isolation; use `UserDefaults(suiteName: UUID().uuidString)` in tests.
- Menu bar UI uses `MenuBarExtra` with `.menu` style, so layout behavior is constrained.
- Permission prompts and TCC behavior depend on code signing; the build script signs the app automatically.
- Upcoming meeting loading requires full calendar read access; `.writeOnly` should be treated as upgrade-required, not as a readable success state.

## What done means

A change is done when:
- the code builds successfully
- the app bundle is produced successfully
- the changed workflow works in the running app
- docs are updated if user-facing behavior changed
- no unnecessary warnings or naming inconsistencies were introduced

## How to verify work

Minimum verification:

```bash
swift test
swift build -c debug
bash scripts/build-app.sh debug
```

For release-facing changes:

```bash
bash scripts/build-app.sh release
```

Manual verification checklist:
- app launches from `TokDown.app`
- menu bar icon appears correctly
- recording can start and stop
- transcript markdown is written to the chosen folder
- selected meetings add calendar front matter to the transcript
- transcript filenames stay date-first, use a meaningful title instead of a generic `Recording`, and avoid overwriting same-minute collisions
- temporary audio file is permanently deleted after transcription instead of being moved to Trash
- the selected transcript folder contains markdown output only, not temporary audio
- settings window opens, saves changes, and persists Meeting Audio or Microphone Only
- Meeting Audio captures both a remote voice from system output and a local voice from the microphone, including when headphones are connected
- permission prompts and denied/upgrade-required status messages still make sense for the changed workflow
- system-audio recordings fail loudly instead of silently writing `(No transcript)` when no audio samples arrive

## Transcript format contract

Expected output shape:

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

Manual recordings keep the same markdown structure but omit calendar-specific fields and infer a better title from the transcript when possible.

Keep this format stable unless there is a clear product reason to change it, and document any format change in `README.md`.
