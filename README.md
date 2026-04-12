# TokDown

iOS app that connects to a [Limitless Pendant](https://www.limitless.ai/) via BLE, transcribes audio on-device using Apple Speech, and pushes markdown transcripts to GitHub.

TokDown supports two transcription paths:
- `Low Power` (default) — capture pendant audio first, transcribe after stop
- `Live` — show a live transcript while recording

Companion to [TokDown for macOS](https://github.com/amadad/tokdown).

## How It Works

```
Pendant (BLE) -> Opus capture/decode -> Speech recognition -> Markdown -> GitHub
```

1. Connects to Limitless Pendant over Bluetooth LE
2. Receives protobuf-fragmented Opus audio frames from the pendant
3. Either:
   - transcribes live with on-device `SFSpeechRecognizer`, or
   - stores Opus frames for deferred transcription after stop (`Low Power`)
4. Formats as timestamped markdown with YAML front matter
5. Pushes to GitHub via Contents API

## Features

- **Manual or calendar-driven recording** -- auto-start/stop based on calendar events
- **Low Power or Live transcription** -- choose battery-friendly deferred transcription or live transcript preview
- **On-device transcription** -- no cloud APIs, works offline
- **Background recording** -- continues when app is backgrounded
- **Auto-reconnect with backoff** -- recovers from BLE disconnects without constant 2-second retries
- **Transcript editing** -- review and edit before pushing
- **Push queue** -- retries failed pushes when network returns

## Requirements

- iOS 18.0+
- Xcode 16+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Limitless Pendant (or compatible BLE device)

## Setup

```bash
xcodegen generate
open TokDown.xcodeproj
```

For CLI device builds, pass your signing team explicitly:

```bash
xcodebuild -project TokDown.xcodeproj -scheme TokDown \
  -destination 'generic/platform=iOS' \
  -derivedDataPath .build/DerivedData \
  -configuration Debug \
  DEVELOPMENT_TEAM=<TEAM_ID> build
```

Add your GitHub PAT in the app's Settings screen. Transcripts push to the configured repo.

The app defaults to `Low Power` transcription mode for better battery life on longer recordings. Switch to `Live` in Settings when you want real-time transcript feedback.

## Architecture

| File | Purpose |
|------|---------|
| `PendantBLE.swift` | CoreBluetooth manager, BLE handshake |
| `LimitlessProtocol.swift` | Protobuf encode/decode, fragment reassembly, Opus extraction |
| `OpusStreamDecoder.swift` | libopus wrapper |
| `OpusCaptureFile.swift` | Temp Opus frame capture for Low Power mode |
| `TranscriptionService.swift` | Chunked SFSpeechRecognizer |
| `SessionManager.swift` | Pipeline orchestrator for Live and Low Power modes |
| `TranscriptFormatter.swift` | Markdown + YAML front matter |
| `GitHubSync.swift` | GitHub Contents API push |
| `PushQueue.swift` | Offline retry queue |

## License

MIT
