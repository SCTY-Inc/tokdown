# CLAUDE.md -- TokDown

iOS companion to TokDown (macOS). Connects to Limitless Pendant via BLE -> live or deferred on-device transcription -> markdown -> GitHub push.

Sibling: [TokDown for macOS](https://github.com/amadad/tokdown)

## Build & Run
```bash
xcodegen generate                    # regenerate xcodeproj from project.yml (required after adding files)
open TokDown.xcodeproj               # Xcode app target with Info.plist + device install support
# CLI deploy:
xcodebuild -project TokDown.xcodeproj -scheme TokDown -destination 'generic/platform=iOS' -derivedDataPath .build/DerivedData -configuration Debug DEVELOPMENT_TEAM=<TEAM_ID> build
xcrun devicectl device install app --device <UDID> .build/DerivedData/Build/Products/Debug-iphoneos/TokDown.app
xcrun devicectl device process launch --device <UDID> com.amadad.tokdown
```

## Architecture
BLE RX notifications -> FragmentReassembler -> OpusFrameExtractor ->
- Live mode: OpusStreamDecoder -> TranscriptionService (chunked SFSpeechRecognizer while recording)
- Low Power mode: OpusCaptureFile -> stop recording -> durable .opusframes recovery file -> OpusStreamDecoder -> PCMRenderFile -> SFSpeechURLRecognitionRequest
-> TranscriptFormatter -> GitHubSync / PushQueue

States: idle -> recording -> transcribing -> pushing

Transcription modes:
- `lowPower` (default) -- capture Opus during recording, transcribe after stop for better battery life
- `live` -- live transcript while recording, higher battery use

Key files:
- `LimitlessProtocol.swift` -- protobuf encode/decode, BLE commands (timeSync, enableDataStream, disableDataStream), FragmentReassembler, OpusFrameExtractor
- `OpusStreamDecoder.swift` -- libopus wrapper (Opus.Decoder from swift-opus)
- `OpusCaptureFile.swift` -- length-prefixed Opus frame capture for Low Power mode; writes `.opusframes.partial` during capture and finalizes to durable `Documents/TranscriptionRecovery/*.opusframes` before transcription
- `PCMRenderFile.swift` -- renders deferred PCM audio to a local `.caf` file for `SFSpeechURLRecognitionRequest`
- `SpeechLanguageModelCache.swift` -- builds and caches custom Speech language models from contextual phrases when available
- `PendantBLE.swift` -- CoreBluetooth manager, retrieve-known reconnect path, filtered scan/service discovery, reconnect backoff
- `TranscriptionService.swift` -- chunked live transcription + file-based deferred transcription, on-device checks, custom vocabulary prewarm, short-tail finalization, boundary-only chunk overlap merging
- `SessionManager.swift` -- pipeline orchestrator; chooses live vs deferred transcription path, collects contextual vocabulary from meetings, reloads saved front matter with escaped-quote-safe parsing; `transcribeOpusFile(at:)` is the shared decode→render→speech core used by both the normal deferred path and recovery retries; exposes `frameRate` (frames/sec, updated every 1s by elapsedTimer) and `recoveryFiles()` / `retryRecovery(at:)` / `deleteRecovery(at:)` for the recovery UI
- `PushQueue.swift` -- offline retry queue with push timing policies (immediate / Wi‑Fi / charging); `credentialError` is set on 401/403 and cleared by `clearCredentialError()` when a new PAT is saved; `retryAfter: Date?` on `PendingPush` gates drain() on the Retry-After window; `items` exposes the queue read-only for UI
- `GitHubSync.swift` -- GitHub Contents API push; `SyncError.rateLimited(retryAfter:)` carries the Retry-After seconds parsed from the response header (default 60s); `isCredentialError` true for 401/403; uses a private static `URLSession` with `timeoutIntervalForRequest: 20` (not `URLSession.shared`) so the queue fails fast on bad networks
- `MetricsCollector.swift` + `PerformanceTrace.swift` -- MetricKit payload capture and signpost instrumentation
- `TranscriptFormatter.swift` -- YAML front matter + timestamped markdown
- `DebugLog.swift` -- writes to Documents/debug.log for on-device diagnostics
- `PushQueueView.swift` -- status screen showing queued items, retry counts, last errors, rate-limit state; accessible from Settings > Diagnostics
- `RecoveryView.swift` -- browse and retry .opusframes files in Documents/TranscriptionRecovery; swipe-to-delete; retry calls `transcribeOpusFile(at:)` directly, bypassing session state machine
- `DebugLogView.swift` -- reads Documents/debug.log in a monospace ScrollView; Copy + Refresh toolbar; only linked in Settings under `#if DEBUG`
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
Markdown transcripts pushed to a configurable GitHub repo (set in Settings) at `{path}/YYYY-MM-DD_HH-mm-ss-SSS_Title.md`.
YAML front matter follows the TokDown archive contract: `audio_source: "limitless_pendant"`, plus `source: "manual_recording"` or `"calendar_selection"`.
Calendar-linked pendant recordings include `calendar_provider: "apple_calendar"` and the available EventKit fields.

## Dependencies
- [alta/swift-opus](https://github.com/alta/swift-opus) v0.0.2 -- libopus SPM package (compiles C source)
- Apple frameworks: CoreBluetooth, Speech, EventKit, AVFoundation, Security, Observation

## Gotchas
- Limitless Pendant uses protobuf-wrapped BLE protocol (NOT standard Omi 3-byte header)
- Must send timeSync before enableDataStream; enableDataStream sent only when recording starts (not on connect) to preserve pendant battery
- `lowPower` is the default transcription mode; it captures raw Opus frames to a `.opusframes.partial` file, finalizes to `Documents/TranscriptionRecovery/*.opusframes`, renders PCM `.caf`, then transcribes with `SFSpeechURLRecognitionRequest`
- Speech permission is requested when recording starts. Calendar permission is requested when calendar mode is enabled, not on ordinary launch.
- If deferred transcription fails or times out, keep the finalized `.opusframes` file under `Documents/TranscriptionRecovery` instead of deleting the only recoverable audio
- `live` mode keeps `SFSpeechRecognizer` active during recording and costs noticeably more battery than `lowPower`
- disableDataStream (realTimeMode=0) sent when recording stops; speculative — verify pendant honors it
- Incoming audio is protobuf-fragmented; needs reassembly before Opus decode
- Protobuf decode must fail closed on malformed/truncated length-delimited fields; don't compute end offsets before proving enough remaining bytes
- AudioToolbox kAudioFormatOpus has iOS 18 bug (FB15344866) returning 1 sample per call -- must use libopus
- Code signing required for BLE, Speech, and Calendar permissions
- Swift 6 concurrency: actor isolation rules apply; closures in @MainActor contexts inherit isolation
- Swift 6 + CoreBluetooth: @MainActor on CBDelegate class doesn't work -- delegate conformance crosses isolation boundary and non-Sendable params ([String: Any]) trigger "sending risks data races". Keep @unchecked Sendable with queue: nil invariant instead
- Keychain service name: "tokdown"
- SFSpeechRecognizer.requestAuthorization callback runs on background queue -- must use nonisolated
- On-device recognition should be gated with `supportsOnDeviceRecognition`; TokDown now fails closed instead of silently allowing off-device recognition
- `bestTranscription.segments` can be empty even when `formattedString` contains transcript text; fall back to formatted text and filter whitespace-only lines to avoid empty `[00:00]` saves
- File transcription must clear `fullText` and `lastNonEmptySnapshot` before each new prerecorded-audio run so timeout/error fallback can't leak the previous recording into the next save
- Short live chunks still need `endAudio()` and a brief finalization wait; returning early drops exactly the short tails most likely to need final recognition
- Chunk overlap dedupe should happen only at chunk boundaries; don't compare adjacent segment tokens or you'll delete legitimate repetitions like "very very"
- Live SFSpeechRecognizer silently degrades after ~1 min continuous audio -- chunked recognition restarts every 45s of audio, not wall-clock time
- Opus frames nested 4 levels deep in protobuf: outer field 2 -> inner field 6 -> repeated field 3 -> field 4 (raw Opus)
- Opus TOC byte from pendant is 0xB8 (CELT-only mono 20ms)
- Uses @Observable (Observation framework), not ObservableObject -- views use @Environment(Type.self) not @EnvironmentObject
- @Observable + lazy var requires @ObservationIgnored (macro conflicts with lazy's computed property mechanics)
- BLE opus frames delivered via AsyncStream (not Combine) -- SessionManager consumes with for-await Task
- Reconnect flow should try `retrieveConnectedPeripherals(withServices:)` and `retrievePeripherals(withIdentifiers:)` before scanning; persisted identifiers help, but unpaired BLE identity can still rotate
- CB state restoration: willRestoreState may return peripheral in .connecting state (not .connected) -- handle both
- XcodeGen `info: path:` regenerates the plist -- use INFOPLIST_FILE build setting instead
- BLE writes to pendant must use .withResponse, not .withoutResponse
- 1-second delays required between subscribe -> timeSync; additional 1s before enableDataStream auto-fires if recording waiting
- BLE reconnect during recording: completeHandshake() auto-enables streaming if opusFrameContinuation is active
- BLE scanning/discovery should stay filtered to the pendant service/characteristics to reduce radio and CPU work
- BLE reconnect now backs off from 2s up to 30s to reduce idle battery drain when the pendant is unavailable
- PushQueue can defer GitHub sync until Wi‑Fi or charging; use `Push timing` in Settings for larger archives / better battery
- PushQueue drains by item ID now; don't overwrite the full queue after awaited network work or you'll lose transcripts enqueued mid-drain
- Permanent GitHub sync failures (missing PAT/repo, non-retryable 4xxs) should stay queued with a visible error instead of burning retry budget and disappearing
- Build GitHub Contents API URLs by encoding each repo path segment; don't interpolate raw `basePath` / `filename` into the URL string
- MetricKit + signposts are wired for measuring battery regressions instead of guessing
- Keychain uses kSecAttrAccessibleWhenUnlockedThisDeviceOnly for PAT storage
- LimitlessCommand.messageIndex uses OSAllocatedUnfairLock for thread-safe atomic access
- `FragmentReassembler` should reject out-of-range `fragmentSeq` values and only assemble when the fragment key set is exactly `0..<totalFragments`
- `CalendarService.Meeting.id` should use EventKit's `eventIdentifier`, not a fresh UUID on each refresh, to keep SwiftUI diffing stable
- GitHub 429 is no longer retryable via `isRetryable`; it's caught before the generic handler in `PushQueue.drain()` and sets `retryAfter` on the item — the drain() catch clauses must stay in order: `GitHubSync.SyncError` first, generic `Error` fallback second
- `credentialError` on PushQueue is NOT cleared automatically on push retry; only `clearCredentialError()` via SettingsView's PAT save flow clears it
- `frameRate` reflects frames received in the previous 1-second window (updated by elapsedTimer); it will read 0 for the first second of recording
- `transcribeOpusFile(at:)` is `internal` (not `private`) so RecoveryView's retry path can call it from SessionManager without touching the session state machine; don't promote to public or call from outside the app module
- `DebugLogView` is only wired into SettingsView under `#if DEBUG`; the log file still exists in release builds (DebugLog is a no-op), so reading it in release is safe but shows nothing
- Don't include `kSecAttrAccessible` in `SecItemCopyMatching` read queries — it's a write-time attribute and silently returns `errSecItemNotFound` if the stored item's accessibility value differs from the query constraint
- `TranscriptDetailView` re-push routes through `PushQueue.enqueue()`, not `GitHubSync.push()` directly — status shows "Queued" not "Pushed"; offline retry, timing policy, and credential-error handling all apply
- `GitHubSync` uses a private static `URLSession` with `timeoutIntervalForRequest: 20`; don't switch back to `URLSession.shared` — the 60s default stalls PushQueue drain for a full minute per failed attempt on unreachable hosts
