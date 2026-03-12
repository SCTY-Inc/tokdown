# TokDown

**Talk in. Markdown out.**

TokDown is a macOS menu bar app that captures system audio and turns it into agent-ready markdown.

It uses Apple’s newer on-device transcription pipeline on macOS 26, keeps processing local, and deletes audio after transcription so you keep the transcript, not the recording archive.

## Why TokDown

Most transcription tools create another silo. TokDown creates plain markdown you can search, version, summarize, commit, and feed directly into your agents.

### Built for agent workflows

- capture meetings, calls, demos, and research audio
- save clean markdown instead of trapping notes in another app
- keep transcripts local and easy to pass into prompts, tools, and automations
- avoid API keys, cloud upload, and audio-file sprawl

## How it works

1. Launch TokDown
2. Click the menu bar icon
3. Pick an upcoming meeting or start recording immediately
4. Stop when you're done
5. TokDown transcribes locally and saves a timestamped `.md` file
6. The recorded audio file is deleted automatically

By default, transcripts are saved to:

```text
~/Documents/Transcripts/
```

Example files:

```text
2026-03-09_17-38_Standup.md
2026-03-09_18-00_Recording.md
```

## Features

- **System audio capture** via ScreenCaptureKit
- **Apple SpeechTranscriber transcription** with downloadable on-device assets
- **Timestamped markdown output** for downstream agent workflows
- **Calendar integration** for quick meeting targeting
- **No audio files retained** after transcript generation
- **No API keys or external services**
- **Custom menu bar status icon** for idle, recording, and transcribing states

## Requirements

- macOS 26+
- Xcode 15+

## Build from source

```bash
bash scripts/build-app.sh debug
open TokDown.app
```

TokDown is a menu bar app, so it does not show a dock icon after launch. It lives in the menu bar.

To create a release build and zip archive:

```bash
bash scripts/build-app.sh release
```

This produces:

- `TokDown.app`
- `TokDown.app.zip`

## Install from GitHub Releases

1. Download the latest `TokDown.app.zip` from the Releases page
2. Unzip it
3. Move `TokDown.app` to `/Applications`
4. Launch it
5. If macOS warns on first run, use right-click → **Open**

## Permissions

On first use, macOS will ask for permissions depending on your workflow:

- **Screen Recording** — required for system audio capture
- **Speech Recognition** — required for transcription
- **Calendar** — optional, used to show upcoming meetings

## Transcript format

```markdown
# Standup

2026-03-09 14:00–14:30

[00:05] First chunk of transcribed text grouped by ~5s windows.

[00:10] Next chunk continues here with natural grouping.
```

The output is intentionally simple:

- plain markdown
- easy to diff and version
- easy to summarize with agents
- easy to archive in a folder, repo, or notes system

## Stack

Swift 6, SwiftUI, Swift Package Manager. No external dependencies.

Frameworks:

- ScreenCaptureKit
- AVFoundation
- Speech
- EventKit

## Architecture

```text
Sources/TokDown/
├── TokDownApp.swift            # App entry point
├── MenuBarCoordinator.swift    # State machine (idle → recording → transcribing)
├── MenuBarIconView.swift       # Custom menu bar icon states
├── MenuBarViews.swift          # Menu bar + Settings window
├── SystemAudioService.swift    # ScreenCaptureKit audio capture
├── RecordingService.swift      # AVAudioRecorder (mic mode)
├── TranscriptionService.swift  # Apple SpeechTranscriber pipeline
├── StorageService.swift        # File output
├── CalendarService.swift       # EventKit meetings
├── AppModels.swift             # Data types
└── Resources/
    ├── Info.plist
    ├── TokDown.entitlements
    └── TokDownIcon.svg         # Starter app icon concept source
```

## Current status

TokDown is ready for GitHub distribution as a signed app bundle packaged from the build script.

Planned polish:

- proper `.icns` app icon generation
- notarized public releases
- better transcript post-processing for agent ingestion
- screenshots and demo media

## License

MIT
