# TokDown

iOS app that connects to a [Limitless Pendant](https://www.limitless.ai/) via BLE, transcribes audio on-device using Apple Speech, and pushes markdown transcripts to GitHub.

Companion to [TokDown for macOS](https://github.com/amadad/tokdown).

## How It Works

```
Pendant (BLE) -> Opus decode -> Speech recognition -> Markdown -> GitHub
```

1. Connects to Limitless Pendant over Bluetooth LE
2. Decodes Opus audio frames via [libopus](https://github.com/alta/swift-opus)
3. Transcribes with on-device `SFSpeechRecognizer` (chunked every 45s)
4. Formats as timestamped markdown with YAML front matter
5. Pushes to GitHub via Contents API

## Features

- **Manual or calendar-driven recording** -- auto-start/stop based on calendar events
- **On-device transcription** -- no cloud APIs, works offline
- **Background recording** -- continues when app is backgrounded
- **Auto-reconnect** -- recovers from BLE disconnects mid-recording
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

## Architecture

| File | Purpose |
|------|---------|
| `PendantBLE.swift` | CoreBluetooth manager, BLE handshake |
| `LimitlessProtocol.swift` | Protobuf encode/decode, fragment reassembly, Opus extraction |
| `OpusStreamDecoder.swift` | libopus wrapper |
| `TranscriptionService.swift` | Chunked SFSpeechRecognizer |
| `SessionManager.swift` | Pipeline orchestrator |
| `TranscriptFormatter.swift` | Markdown + YAML front matter |
| `GitHubSync.swift` | GitHub Contents API push |
| `PushQueue.swift` | Offline retry queue |

## License

MIT
