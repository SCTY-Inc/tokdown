# CLAUDE.md -- TokDown

iOS companion to TokDown (macOS). Connects to Limitless Pendant via BLE -> on-device speech recognition -> markdown -> GitHub push.

Sibling: [TokDown for macOS](https://github.com/amadad/tokdown)

## Build & Run
```bash
xcodegen generate                    # regenerate xcodeproj from project.yml (required after adding files)
open TokDown.xcodeproj               # Xcode app target with Info.plist + device install support
# CLI deploy:
xcodebuild -project TokDown.xcodeproj -scheme TokDown -destination 'generic/platform=iOS' -derivedDataPath .build/DerivedData -configuration Debug build
xcrun devicectl device install app --device <UDID> .build/DerivedData/Build/Products/Debug-iphoneos/TokDown.app
xcrun devicectl device process launch --device <UDID> com.amadad.tokdown
```

## Architecture
BLE RX notifications -> FragmentReassembler -> OpusFrameExtractor -> OpusStreamDecoder (libopus via swift-opus) -> TranscriptionService (SFSpeechRecognizer, chunked) -> TranscriptFormatter -> GitHubSync

States: idle -> recording -> transcribing -> pushing

Key files:
- `LimitlessProtocol.swift` -- protobuf encode/decode, BLE commands (timeSync, enableDataStream, disableDataStream), FragmentReassembler, OpusFrameExtractor
- `OpusStreamDecoder.swift` -- libopus wrapper (Opus.Decoder from swift-opus)
- `PendantBLE.swift` -- CoreBluetooth manager, Limitless handshake, name-based scan filter
- `TranscriptionService.swift` -- chunked SFSpeechRecognizer (restarts every 45s to avoid ~1min degradation)
- `SessionManager.swift` -- pipeline orchestrator, Opus frames -> decode -> transcribe
- `TranscriptFormatter.swift` -- YAML front matter + timestamped markdown
- `DebugLog.swift` -- writes to Documents/debug.log for on-device diagnostics
- `project.yml` -- XcodeGen config (source of truth for xcodeproj)

## BLE Protocol (Limitless Pendant)
- Service: 632DE001-604C-446B-A80F-7963E950F3FB
- TX (WRITE): 632DE002 -- send protobuf-encoded commands to pendant
- RX (NOTIFY): 632DE003 -- receive protobuf-wrapped audio/responses
- Battery: standard 0x180F / 0x2A19
- Handshake: subscribe RX notify -> write timeSync to TX (enableDataStream sent on-demand when recording starts)
- Audio: Opus FS320 (20ms frames, 320 samples at 16kHz mono), protobuf-fragmented
- Pendant advertises as "Pendant" (not "Friend" or "Omi")

## Output
Markdown transcripts pushed to a configurable GitHub repo (set in Settings) at `{path}/YYYY-MM-DD_HH-mm_Title.md`.
YAML front matter with `audio_source: "limitless_pendant"`, `source: "pendant_ambient"` or `"pendant_meeting"`.
Same format as TokDown macOS -- transcripts are indistinguishable in the archive.

## Dependencies
- [alta/swift-opus](https://github.com/alta/swift-opus) v0.0.2 -- libopus SPM package (compiles C source)
- Apple frameworks: CoreBluetooth, Speech, EventKit, AVFoundation, Security, Observation

## Gotchas
- Limitless Pendant uses protobuf-wrapped BLE protocol (NOT standard Omi 3-byte header)
- Must send timeSync before enableDataStream; enableDataStream sent only when recording starts (not on connect) to preserve pendant battery
- disableDataStream (realTimeMode=0) sent when recording stops; speculative — verify pendant honors it
- Incoming audio is protobuf-fragmented; needs reassembly before Opus decode
- AudioToolbox kAudioFormatOpus has iOS 18 bug (FB15344866) returning 1 sample per call -- must use libopus
- Code signing required for BLE, Speech, and Calendar permissions
- Swift 6 concurrency: actor isolation rules apply; closures in @MainActor contexts inherit isolation
- Swift 6 + CoreBluetooth: @MainActor on CBDelegate class doesn't work -- delegate conformance crosses isolation boundary and non-Sendable params ([String: Any]) trigger "sending risks data races". Keep @unchecked Sendable with queue: nil invariant instead
- Keychain service name: "tokdown"
- SFSpeechRecognizer.requestAuthorization callback runs on background queue -- must use nonisolated
- SFSpeechRecognizer silently degrades after ~1 min continuous audio -- chunked recognition restarts every 45s
- Opus frames nested 4 levels deep in protobuf: outer field 2 -> inner field 6 -> repeated field 3 -> field 4 (raw Opus)
- Opus TOC byte from pendant is 0xB8 (CELT-only mono 20ms)
- Uses @Observable (Observation framework), not ObservableObject -- views use @Environment(Type.self) not @EnvironmentObject
- @Observable + lazy var requires @ObservationIgnored (macro conflicts with lazy's computed property mechanics)
- BLE opus frames delivered via AsyncStream (not Combine) -- SessionManager consumes with for-await Task
- CB state restoration: willRestoreState may return peripheral in .connecting state (not .connected) -- handle both
- XcodeGen `info: path:` regenerates the plist -- use INFOPLIST_FILE build setting instead
- BLE writes to pendant must use .withResponse, not .withoutResponse
- 1-second delays required between subscribe -> timeSync; additional 1s before enableDataStream auto-fires if recording waiting
- BLE reconnect during recording: completeHandshake() auto-enables streaming if opusFrameContinuation is active
- Keychain uses kSecAttrAccessibleWhenUnlockedThisDeviceOnly for PAT storage
- LimitlessCommand.messageIndex uses OSAllocatedUnfairLock for thread-safe atomic access
