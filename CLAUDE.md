# CLAUDE.md -- TokDown Mobile

iOS companion to TokDown (macOS). Connects to Limitless Pendant (Omi BLE protocol) -> on-device speech recognition -> markdown -> GitHub push.

Repo: SCTY-Inc/tokdown-mobile
Sibling: amadad/tokdown (macOS menu bar app)

## Build & Run
```bash
open Package.swift   # Xcode, select iOS simulator or device
```

## Architecture
BLE audio -> OpusDecoder -> TranscriptionService (SFSpeechRecognizer) -> TranscriptFormatter -> GitHubSync

States: idle -> recording -> transcribing -> pushing

## BLE Protocol (Omi-compatible)
- Service: 19B10000-E8F2-537E-4F6C-D104768A1214
- Audio Data (NOTIFY): 19B10001 -- raw Opus frames with 3-byte header
- Codec Type (READ): 19B10002
- Battery: standard 0x180F / 0x2A19

## Output
Markdown transcripts pushed to `amadad/agents` repo at `intel/transcripts/YYYY-MM-DD_HH-mm_Title.md`.
YAML front matter with `audio_source: "limitless_pendant"`, `source: "pendant_ambient"` or `"pendant_meeting"`.
Same format as TokDown macOS -- transcripts are indistinguishable in the archive.

## Dependencies
- None. libopus will be vendored later for Opus decoding.
- Apple frameworks: CoreBluetooth, Speech, EventKit, AVFoundation, Security

## Gotchas
- BLE audio packets have 3-byte header (sequence + metadata) before Opus data
- Code signing required for BLE, Speech, and Calendar permissions
- Swift 6 concurrency: actor isolation rules apply
- Keychain service name: "tokdown-mobile"
- Opus decode is passthrough until libopus is vendored
