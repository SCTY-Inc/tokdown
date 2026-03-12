# AGENTS.md — TokDown

Scope: this repository

## What this repo is

TokDown is a macOS menu bar app that captures system audio or microphone input and saves agent-ready markdown transcripts.

Core product constraints:
- local transcription only
- no external dependencies
- no API keys
- audio files are deleted after transcription
- output is plain markdown in a user-selected folder

## Repo layout

```text
.
├── Package.swift
├── README.md
├── AGENTS.md
├── CLAUDE.md
├── scripts/
│   └── build-app.sh
└── Sources/
    └── TokDown/
        ├── TokDownApp.swift
        ├── MenuBarCoordinator.swift
        ├── MenuBarIconView.swift
        ├── MenuBarViews.swift
        ├── SystemAudioService.swift
        ├── RecordingService.swift
        ├── TranscriptionService.swift
        ├── CalendarService.swift
        ├── StorageService.swift
        ├── SettingsStore.swift
        ├── AppModels.swift
        └── Resources/
            ├── Info.plist
            ├── TokDown.entitlements
            └── TokDownIcon.svg
```

## Important files

- `Sources/TokDown/TokDownApp.swift` — app entry, menu bar scene, settings window
- `Sources/TokDown/MenuBarCoordinator.swift` — state machine and orchestration
- `Sources/TokDown/SystemAudioService.swift` — system audio capture via ScreenCaptureKit
- `Sources/TokDown/RecordingService.swift` — microphone capture fallback
- `Sources/TokDown/TranscriptionService.swift` — Apple SpeechTranscriber pipeline
- `Sources/TokDown/StorageService.swift` — transcript output and cleanup
- `Sources/TokDown/CalendarService.swift` — upcoming meetings and calendar permissions
- `scripts/build-app.sh` — build, bundle, sign, and zip release artifact

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

## Build, test, and lint commands

There is no separate test suite or lint setup yet.

Use these checks before submitting changes:

```bash
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
- The app uses Apple’s newer on-device SpeechTranscriber pipeline.
- ScreenCaptureKit still requires a minimal video config even for audio-only capture.
- Menu bar UI uses `MenuBarExtra` with `.menu` style, so layout behavior is constrained.
- Permission prompts and TCC behavior depend on code signing; the build script signs the app automatically.

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
- audio file is deleted after transcription
- settings window opens and saves changes
- permission prompts still make sense for the changed workflow

## Transcript format contract

Expected output shape:

```markdown
# Meeting Title

2026-03-09 14:00–14:30

[00:05] First chunk of transcribed text grouped by ~5s windows.

[00:10] Next chunk continues here with natural grouping.
```

Keep this format stable unless there is a clear product reason to change it, and document any format change in `README.md`.
