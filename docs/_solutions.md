# Solutions Log

## 2026-04-15: loadPAT silently returned nil when Keychain item accessibility differed from query constraint
**Problem**: `GitHubSync.loadPAT()` could return nil even when a valid PAT was stored, causing all pushes to fail with `missingPAT` and no diagnosis.
**Root cause**: `SecItemCopyMatching` was passed `kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly` as a search constraint. This attribute is write-time only; as a query filter it silently returns `errSecItemNotFound` if the stored item's accessibility value doesn't match exactly — including items created by an older code path or a different accessibility setting.
**Fix**: Removed `kSecAttrAccessible` from the `loadPAT` read query. The attribute remains on `savePAT` and `addQuery` where it correctly constrains the stored item's accessibility.

## 2026-04-15: No visibility into queued push failures, rate limits, or credential errors
**Problem**: GitHub push failures (wrong PAT, 429 rate limits, offline) were invisible — items silently piled up or vanished, and users had no way to see queue state, retry counts, or error messages without reading debug.log via devicectl.
**Root cause**: `PushQueue` had rich internal state (`retryCount`, `lastError`, timing) but no public surface; 429 was incorrectly classified alongside other retryable errors with no back-off; 401/403 burned retry budget and disappeared; no UI screen existed for the queue.
**Fix**: Added `PushQueueView` (Settings > Diagnostics) showing each item with status badge, retry count, last error, and rate-limit countdown. Added `credentialError` property set on 401/403, shown as a distinct red banner in ContentView with "Update in Settings →" link. Added `SyncError.rateLimited(retryAfter:)` case: parses `Retry-After` header (default 60s, ceiling 3600s), sets `retryAfter: Date?` on the `PendingPush` item, skipped in `drain()` until window expires. `catch` clauses in `drain()` now match `GitHubSync.SyncError` before the generic `Error` fallback so rate-limit and credential cases are handled distinctly.

## 2026-04-15: Failed Low Power transcriptions left unrecoverable audio with no user action path
**Problem**: When deferred transcription failed, `.opusframes` files were preserved in `Documents/TranscriptionRecovery` with a message in `lastError`, but there was no UI to browse, retry, or delete them. Users could lose transcripts without realising audio was recoverable.
**Root cause**: Recovery preservation existed but was only visible in the generic error banner. The retry logic was tightly coupled to `SessionManager`'s live session state (`deferredCapture` ivar, state transitions), making it impossible to call from a UI without faking a recording session.
**Fix**: Extracted the decode→render→speech core into `transcribeOpusFile(at:)` (internal, not private) so recovery can call it with an explicit URL without touching session state. Added `recoveryFiles()` / `retryRecovery(at:)` / `deleteRecovery(at:)` to `SessionManager`. Created `RecoveryView` (Settings > Diagnostics) listing `.opusframes` files by date with size, swipe-to-delete, and a Retry button that runs the full transcription pipeline and saves/pushes the result.

## 2026-04-15: No visual confirmation that pendant audio is flowing during recording
**Problem**: During Low Power mode (and sometimes Live mode), the recording card showed no indication of whether Opus frames were actually arriving from the pendant. If the pendant drifted out of range mid-recording, users had no feedback until transcription produced nothing.
**Root cause**: Frame arrival was tracked internally (`decodedFrameCount`) but not exposed to the UI.
**Fix**: Added `frameRate: Double` to `SessionManager` — updated each second by the existing `elapsedTimer` from a `framesThisSecond` counter incremented in `processOpusFrame`. Added a 5-bar capsule indicator in `recordingCard` (bars light at 10/20/30/40/50 fps; normal pendant rate is ~50 fps for 20ms Opus frames).

## 2026-04-12: Transcript save/sync edge cases could overwrite, mislabel, or silently discard work
**Problem**: Several normal-path failures could corrupt transcript handling: malformed protobuf notifications could crash decode, same-minute recordings could overwrite each other locally/remotely, deferred transcription timeouts could reuse the previous recording's text, short live tails could be dropped before finalization, and permanent GitHub failures could disappear after exhausting retry budget.
**Root cause**: Multiple components assumed happy-path inputs or treated all failures the same. `Protobuf.decode()` computed length-delimited end indexes before proving bounds, transcript filenames only used minute precision, file transcription teardown kept stale fallback state alive, live finalization skipped `endAudio()` for short chunks, and `PushQueue` incremented retries for every failure class.
**Fix**: Made protobuf parsing fail closed, tightened fragment reassembly validation, switched transcript filenames to `yyyy-MM-dd_HH-mm-ss-SSS_Title.md`, reset prerecorded transcription state before each run, finalize short live chunks with a brief `endAudio()` wait, restrict overlap removal to chunk-boundary merges, keep permanent GitHub failures queued with `lastError`, percent-encode GitHub Contents API path segments, parse escaped quotes from saved front matter, and use `eventIdentifier` as the stable calendar row ID.

## 2026-04-11: PushQueue dropped new transcripts enqueued during an in-flight drain
**Problem**: If TokDown queued another transcript while a GitHub push was already awaiting the network, the later item could disappear from the queue.
**Root cause**: `PushQueue.drain()` iterated a snapshot of `queue`, awaited per-item network work, then replaced the entire queue with a `remaining` array. Items appended mid-drain were never in that snapshot and got overwritten.
**Fix**: Drain now processes the initial IDs individually, removes/retries each item by ID, preserves any newly appended items, and schedules another drain pass if work remains. Added a regression test covering enqueue-during-drain.

## 2026-04-11: Low Power transcription failure deleted the only recoverable audio
**Problem**: When deferred transcription failed or timed out, TokDown could still save an empty markdown transcript after deleting the original captured audio.
**Root cause**: `SessionManager` always removed the finalized `.opusframes` capture via `defer`, even if decode/render/speech recognition later failed.
**Fix**: Low Power now deletes the original capture only after successful transcription. On failures or empty deferred results, TokDown preserves the raw capture in `Documents/TranscriptionRecovery`, surfaces that in `lastError`, and adds a timeout to file-based speech recognition so the app doesn't hang in `.transcribing` forever.

## 2026-04-11: Apple-native low-power transcription needed a file-based path, not replaying live buffers
**Problem**: `lowPower` reduced battery drain while recording, but still depended on the live-buffer transcription path at stop, which kept more custom timing/finish logic than necessary.
**Root cause**: Deferred mode decoded Opus back into the chunked live `SFSpeechAudioBufferRecognitionRequest` path instead of using Apple's prerecorded-audio API.
**Fix**: Added `PCMRenderFile` and switched deferred transcription to `SFSpeechURLRecognitionRequest`. TokDown now captures raw Opus frames, renders a local `.caf`, then transcribes the file with `taskHint = .dictation`, `requiresOnDeviceRecognition = true`, contextual phrases, and custom language model prewarm when available.

## 2026-04-11: BLE reconnect and scan path still used more radio than necessary
**Problem**: Even after adding reconnect backoff, TokDown still scanned broadly (`withServices: nil`) and rediscovered every service/characteristic, which cost unnecessary radio and CPU work.
**Root cause**: The central path skipped Apple's retrieve-known workflow and service filtering guidance.
**Fix**: `PendantBLE` now tries `retrieveConnectedPeripherals(withServices:)` and `retrievePeripherals(withIdentifiers:)` before scanning, persists the last pendant identifier, scans only for the pendant service UUID, and discovers only the TX/RX/battery characteristics it actually uses.

## 2026-04-11: Saved transcript collapsed to empty `[00:00]` block despite live text on screen
**Problem**: TokDown showed a reasonable live transcript during recording, but the saved markdown sometimes contained only `[00:00]` or blank content.
**Root cause**: `SFSpeechRecognizer` can produce a final result where `bestTranscription.segments` is empty or whitespace-only even though `formattedString` still contains useful text. The save path trusted the segment list too aggressively, so the formatter emitted an empty timestamp row.
**Fix**: In `TranscriptionService`, preserve the last non-empty snapshot, fall back to `formattedString` when segment data is empty, filter whitespace-only lines, and make chunk timing audio-duration-based instead of wall-clock-based. In `TranscriptFormatter`, ignore whitespace-only lines and fall back to `fullText` instead of emitting an empty `[00:00]` block.

## 2026-04-11: All-day battery target needed a lower-power recording path
**Problem**: Continuous live transcription drained battery too quickly for longer or all-day use.
**Root cause**: The app kept `SFSpeechRecognizer` active throughout the recording session, which is much more expensive than just capturing pendant audio.
**Fix**: Added `TranscriptionMode` with `lowPower` (default) and `live`. `lowPower` stores length-prefixed Opus frames in `OpusCaptureFile`, then decodes/transcribes after stop. Also added BLE reconnect backoff (2s doubling up to 30s) to reduce idle battery drain when the pendant is unavailable.

## 2026-04-07: Limitless Pendant battery drain — enableDataStream sent on every BLE connect
**Problem**: Pendant battery dying fast. Audio data stream was enabled immediately on every BLE connect (including app launch and reconnects), regardless of whether a recording was active.
**Root cause**: `startStreamingHandshake()` sent both `timeSync` and `enableDataStream` whenever the RX characteristic started notifying. The pendant's audio encoder and BLE radio stayed active 24/7.
**Fix**: Split handshake from streaming. `completeHandshake()` only sends `timeSync` on connect. `enableDataStream` is deferred to `startOpusStream()` (called when recording starts). Added `disableDataStream` command (realTimeMode=0) sent on `stopOpusStream()`. Reconnect during recording auto-enables streaming via `handshakeComplete` flag + `opusFrameContinuation` check.

## 2026-04-06: @MainActor on PendantBLE fails in Swift 6 strict concurrency
**Problem**: Making PendantBLE `@MainActor` causes "conformance crosses into main actor-isolated code" for CBCentralManagerDelegate/CBPeripheralDelegate. Using `nonisolated` + `MainActor.assumeIsolated` then triggers "sending 'dict' risks causing data races" for non-Sendable `[String: Any]` params.
**Root cause**: Swift 6 region-based isolation analysis treats `MainActor.assumeIsolated` closure captures as potential cross-isolation sends, even though execution is synchronous. `@preconcurrency import CoreBluetooth` suppresses protocol mismatch warnings but not the sending check.
**Fix**: Keep PendantBLE as non-`@MainActor` `@Observable` class with `@unchecked Sendable`. Thread safety is guaranteed by CBCentralManager `queue: nil` (main queue) invariant, documented in class header. Removed Thread.isMainThread helpers that were unnecessary overhead.

## 2026-04-06: @Observable macro conflicts with lazy var
**Problem**: `@Observable` on AppState causes "init accessor cannot refer to property '_session'" and "'lazy' cannot be used on a computed property" for `lazy var session: SessionManager`.
**Root cause**: `@Observable` macro wraps all stored properties with `@ObservationTracked`, which adds init/get/set accessors. `lazy` is implemented as a computed property + backing storage under the hood, conflicting with the macro's expansion.
**Fix**: Mark with `@ObservationIgnored lazy var session`. This excludes the property from observation tracking, which is correct — views observe session's own `@Observable` properties, not the AppState.session reference itself.

## 2026-04-02: SFSpeechRecognizer truncates transcripts after ~1 minute
**Problem**: 32-second recording produced only one `[00:00]` timestamp block, text cut off mid-sentence.
**Root cause**: SFSpeechRecognizer silently degrades after ~1 minute of continuous audio despite Apple's "no limit" claim for on-device mode. The Omi app avoids this entirely by batching 5-second audio chunks.
**Fix**: Rewrote TranscriptionService with chunked recognition — restarts the recognition task every 30 seconds, commits partial results between chunks, stitches with time offsets. Also batches Opus frames (5 per append = 100ms) to reduce AVAudioPCMBuffer allocation churn. Increased finish timeout from 2s to 5s.

## 2026-04-02: Opus frames extracted with wrong TOC byte (0x08 vs 0xB8)
**Problem**: Extractor found ~80 "frames" per packet with TOC 0x08, but these were protobuf field-3 wrappers, not actual Opus data.
**Root cause**: The audio protobuf nesting is 4 levels deep. The extractor was accepting depth-2 entries as Opus frames. The real Opus bytes are inside field 4 at depth 3+, with TOC byte 0xB8.
**Fix**: Adjusted extractor to only accept frames at depth >= 3 with validated TOC bytes from `validTOCBytes` set.

## 2026-04-02: AudioToolbox Opus decode returns 1 sample per frame on iOS 18
**Problem**: `AudioConverterFillComplexBuffer` with `kAudioFormatOpus` input returns only 1 PCM sample per call instead of 320 (20ms at 16kHz).
**Root cause**: Known iOS 18 bug (FB15344866). Same code works on iOS 17 and macOS.
**Fix**: Replaced AudioToolbox decoder with libopus via `alta/swift-opus` SPM package. Direct `opus_decode()` call returns correct 320 samples.

## 2026-04-02: Opus frame extraction fails — wrong protobuf nesting depth
**Problem**: `OpusFrameExtractor` looked for Opus frames at field 4 depth 0, but Limitless Pendant nests audio at field 6 → field 3 → field 4 (depth 4).
**Root cause**: Assumed Omi-standard flat structure. Limitless wraps audio in: outer field 2 → inner fields 1-6 (field 6 = audio container) → repeated field 3 entries (individual frame wrappers) → field 4 (raw Opus bytes).
**Fix**: Recursive protobuf descent with TOC byte validation (`0xB8` = CELT-only mono 20ms) at depth >= 3.

## 2026-04-02: BLE handshake sends commands but pendant doesn't stream
**Problem**: Time sync + enable data stream commands written via `.withoutResponse`, no audio data received.
**Fix**: Changed to `.withResponse` write type, added 1-second delays between subscribe → timeSync → enableDataStream.

## 2026-04-01: App crashes with _dispatch_assert_queue_fail on launch
**Problem**: SIGTRAP in `_dispatch_assert_queue_fail` during `SFSpeechRecognizer.requestAuthorization`.
**Root cause**: Swift 6 closure isolation inheritance. `TranscriptionService` is `@MainActor`, so the callback closure passed to `requestAuthorization` inherits `@MainActor` isolation. Speech framework calls the handler on a background queue, triggering the dispatch assertion.
**Fix**: Made `requestAuthorization()` `nonisolated` to break actor isolation inheritance on the closure.

## 2026-04-01: Nested ObservableObject changes don't update SwiftUI views
**Problem**: `ContentView` observes `SessionManager` via `@EnvironmentObject`, but `session.ble.connectionState` changes never trigger re-renders.
**Root cause**: SwiftUI `@Published` observation is single-level — nested `ObservableObject` changes don't propagate.
**Fix**: Injected `PendantBLE`, `TranscriptionService`, `CalendarService` as separate `@EnvironmentObject`s. Avoided Combine forwarding (which itself caused actor isolation crashes in Swift 6).

## 2026-04-01: Limitless Pendant not discovered during BLE scan
**Problem**: Scanning with Omi service UUID `19B10000-E8F2-537E-4F6C-D104768A1214` finds nothing.
**Root cause**: Limitless Pendant uses custom service UUID `632DE001-604C-446B-A80F-7963E950F3FB` and advertises as "Pendant", not "Friend"/"Omi".
**Fix**: Scan without UUID filter, match by device name prefix. Added "Pendant" to known prefixes.

## 2026-04-01: CB state restoration crashes with dispatch_assert_queue_fail
**Problem**: App crashes on relaunch when pendant was previously connected.
**Root cause**: `willRestoreState` called `peripheral.discoverServices()` during `CBCentralManager.init`, before the manager's internal queue is set up.
**Fix**: Deferred `discoverServices` to `centralManagerDidUpdateState(.poweredOn)` via `needsServiceDiscovery` flag. Also handle restored peripheral in `.connecting` state (not just `.connected`).
