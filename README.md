# TokDown

**Talk in. Markdown out.**

TokDown is a macOS menu bar app that captures system audio and turns it into agent-ready markdown.

It uses Apple’s newer on-device transcription pipeline on macOS 26, keeps processing local, and deletes audio after transcription so you keep the transcript, not the recording archive.

The app target is still intentionally small at roughly 1.2k lines of Swift, with a small XCTest suite covering transcript formatting.

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
5. TokDown transcribes locally and saves a timestamped `.md` file with YAML front matter
6. The recorded audio file is deleted automatically

By default, transcripts are saved to:

```text
~/Documents/Transcripts/
```

Example files:

```text
2026-03-09_17-38_Standup.md
2026-03-09_18-00_Quarterly_planning_kickoff.md
```

Meeting-backed recordings keep the selected calendar title. The menu shows up to three upcoming meetings across all accessible calendars over the next week. If you record without picking a meeting, TokDown infers a better title from the transcript text when it can, and falls back to the selected audio source name instead of a generic `Recording` label.

## Features

- **System audio capture** via ScreenCaptureKit
- **Apple SpeechTranscriber transcription** with downloadable on-device assets
- **Timestamped markdown output** with YAML front matter for downstream agent workflows
- **Calendar integration** for quick meeting targeting and invite metadata capture
- **No audio files retained** after transcript generation
- **No API keys or external services**
- **Custom menu bar status icon** for idle, recording, and transcribing states

## Requirements

- macOS 26+
- Xcode 15+

## Build from source

```bash
swift test
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
---
title: "Standup"
source: "calendar_selection"
calendar_provider: "apple_calendar"
audio_source: "system_audio"
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
  - name: "Alex Smith"
    email: "alex@example.com"
notes: |
  Agenda and invite notes.
---

# Standup

2026-03-09 14:00–14:30

[00:05] First chunk of transcribed text grouped by ~5s windows.

[00:10] Next chunk continues here with natural grouping.
```

Manual recordings use the same markdown shape, but only include the generic recording fields and omit calendar-specific keys.

The output is intentionally simple:

- plain markdown with structured front matter
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
├── TranscriptFormatter.swift   # Front matter + markdown rendering
├── StorageService.swift        # File output
├── CalendarService.swift       # EventKit meetings
├── AppModels.swift             # Data types
└── Resources/
    ├── Info.plist
    ├── TokDown.entitlements
    └── TokDownIcon.svg         # Starter app icon concept source

Tests/TokDownTests/
└── TranscriptFormatterTests.swift  # Transcript front matter + title inference coverage
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
