# CLAUDE.md -- TokDown Mobile

iOS companion to TokDown (macOS). Connects to Limitless Pendant via BLE -> on-device speech recognition -> markdown -> GitHub push.

Repo: SCTY-Inc/tokdown-mobile
Sibling: amadad/tokdown (macOS menu bar app)

## Build & Run
```bash
xcodegen generate                    # regenerate xcodeproj from project.yml (required after adding files)
open TokDownMobile.xcodeproj         # Xcode app target with Info.plist + device install support
# CLI deploy:
xcodebuild -project TokDownMobile.xcodeproj -scheme TokDownMobile -destination 'generic/platform=iOS' -derivedDataPath .build/DerivedData -configuration Debug build
xcrun devicectl device install app --device <UDID> .build/DerivedData/Build/Products/Debug-iphoneos/TokDownMobile.app
xcrun devicectl device process launch --device <UDID> com.amadad.tokdownmobile
```

## Architecture
BLE RX notifications -> FragmentReassembler -> OpusFrameExtractor -> OpusStreamDecoder (libopus via swift-opus) -> TranscriptionService (SFSpeechRecognizer, chunked) -> TranscriptFormatter -> GitHubSync

States: idle -> recording -> transcribing -> pushing

Key files:
- `LimitlessProtocol.swift` -- protobuf encode/decode, BLE commands (timeSync, enableDataStream), FragmentReassembler, OpusFrameExtractor
- `OpusStreamDecoder.swift` -- libopus wrapper (Opus.Decoder from swift-opus)
- `PendantBLE.swift` -- CoreBluetooth manager, Limitless handshake, name-based scan filter
- `TranscriptionService.swift` -- chunked SFSpeechRecognizer (restarts every 30s to avoid ~1min degradation)
- `SessionManager.swift` -- pipeline orchestrator, Opus frames -> decode -> transcribe
- `TranscriptFormatter.swift` -- YAML front matter + timestamped markdown
- `DebugLog.swift` -- writes to Documents/debug.log for on-device diagnostics
- `project.yml` -- XcodeGen config (source of truth for xcodeproj)

## BLE Protocol (Limitless Pendant)
- Service: 632DE001-604C-446B-A80F-7963E950F3FB
- TX (WRITE): 632DE002 -- send protobuf-encoded commands to pendant
- RX (NOTIFY): 632DE003 -- receive protobuf-wrapped audio/responses
- Battery: standard 0x180F / 0x2A19
- Handshake: subscribe RX notify → write timeSync to TX → write enableDataStream to TX
- Audio: Opus FS320 (20ms frames, 320 samples at 16kHz mono), protobuf-fragmented
- Pendant advertises as "Pendant" (not "Friend" or "Omi")

## Output
Markdown transcripts pushed to `amadad/agents` repo at `intel/transcripts/YYYY-MM-DD_HH-mm_Title.md`.
YAML front matter with `audio_source: "limitless_pendant"`, `source: "pendant_ambient"` or `"pendant_meeting"`.
Same format as TokDown macOS -- transcripts are indistinguishable in the archive.

## Dependencies
- [alta/swift-opus](https://github.com/alta/swift-opus) v0.0.2 — libopus SPM package (compiles C source)
- Apple frameworks: CoreBluetooth, Speech, EventKit, AVFoundation, Security

## Gotchas
- Limitless Pendant uses protobuf-wrapped BLE protocol (NOT standard Omi 3-byte header)
- Must send timeSync + enableDataStream commands before audio flows
- Incoming audio is protobuf-fragmented; needs reassembly before Opus decode
- AudioToolbox kAudioFormatOpus has iOS 18 bug (FB15344866) returning 1 sample per call — must use libopus
- Code signing required for BLE, Speech, and Calendar permissions
- Swift 6 concurrency: actor isolation rules apply; closures in @MainActor contexts inherit isolation
- Keychain service name: "tokdown-mobile"
- SFSpeechRecognizer.requestAuthorization callback runs on background queue — must use nonisolated
- SFSpeechRecognizer silently degrades after ~1 min continuous audio — chunked recognition restarts every 30s
- Opus frames nested 4 levels deep in protobuf: outer field 2 → inner field 6 → repeated field 3 → field 4 (raw Opus)
- Opus TOC byte from pendant is 0xB8 (CELT-only mono 20ms)
- Nested ObservableObject changes don't propagate in SwiftUI — inject BLE/calendar/transcription as separate @EnvironmentObject
- CB state restoration: willRestoreState may return peripheral in .connecting state (not .connected) — handle both
- XcodeGen `info: path:` regenerates the plist — use INFOPLIST_FILE build setting instead
- BLE writes to pendant must use .withResponse, not .withoutResponse
- 1-second delays required between subscribe → timeSync → enableDataStream
