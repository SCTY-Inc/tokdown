# Solutions Log

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
