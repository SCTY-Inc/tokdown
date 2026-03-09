# Echo Log

Minimal macOS menu bar app that records system audio and saves transcripts as markdown files. Built for capturing meetings, calls, and any audio playing on your Mac.

## How it works

1. Click the menu bar icon
2. Pick a calendar meeting or just hit Record
3. Stop when done — transcript saved as `.md`, audio deleted

Output goes to `~/Documents/Transcripts/` as flat markdown files:

```
2026-03-09_17-38_Standup.md
2026-03-09_18-00_Recording.md
```

## Features

- **System audio capture** via ScreenCaptureKit — records everything playing (Zoom, YouTube, etc.) regardless of speakers/headphones
- **Microphone mode** available in Settings
- **Apple Speech transcription** — on-device, no API keys
- **Calendar integration** — shows upcoming meetings as recording targets
- **No audio files saved** — only markdown transcripts (git-friendly)

## Build

Requires macOS 13+ and Xcode 15+.

```bash
bash scripts/build-app.sh debug
open MenuBarRecorder.app
```

First launch will request permissions for:
- Screen Recording (system audio capture)
- Speech Recognition (transcription)
- Calendar (meeting list)

## Stack

Swift 6, SwiftUI, Swift Package Manager. No external dependencies.

Frameworks: ScreenCaptureKit, AVFoundation, Speech, EventKit.

## Architecture

```
Sources/MenuBarRecorder/
├── MenuBarRecorder.swift       # App entry point
├── MenuBarCoordinator.swift    # State machine (idle → recording → transcribing)
├── MenuBarViews.swift          # Menu bar + Settings window
├── SystemAudioService.swift    # ScreenCaptureKit audio capture
├── RecordingService.swift      # AVAudioRecorder (mic mode)
├── TranscriptionService.swift  # Apple Speech recognition
├── StorageService.swift        # File output
├── CalendarService.swift       # EventKit meetings
├── AppModels.swift             # Data types
└── Resources/
    ├── Info.plist
    └── MenuBarRecorder.entitlements
```

~800 lines total. Three states: idle, recording, transcribing.

## License

MIT
