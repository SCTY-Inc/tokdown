# CLAUDE.md — TokDown

TokDown repository: macOS menu bar meeting recorder at the root plus the Limitless Pendant iOS app under `Apps/iOS/`. The macOS app is ~2.1k LOC with focused XCTest and Swift Testing coverage and no dependencies.

## Build & Run
```bash
bash scripts/build-app.sh debug && open TokDown.app
```

## Structure
3 states: idle → recording → transcribing. See AGENTS.md for full architecture.

## Output
`~/Documents/Transcripts/YYYY-MM-DD_HH-mm_Title[-2].md` — date-first filenames, collision-safe suffixing, YAML front matter + markdown body, git-friendly. Audio is normally deleted, but a `.m4a` is **kept** beside the transcript when transcription returns nothing usable (recoverable silent capture).

## Gotchas
- Swift 6 concurrency: no `Task { @MainActor in }` inside completion handlers
- Uses `@Observable` — not `ObservableObject`. Don't introduce `@Published`, `@StateObject`, or `@EnvironmentObject`.
- System audio uses a **Core Audio process tap** (`AudioHardwareCreateProcessTap` + private aggregate device), not ScreenCaptureKit. Reason for the switch: SCK's audio rode a display-bound `SCStream`, so a lid-closed / display-off session captured digital silence → empty transcript. A tap anchors to the default output device and survives lid-close.
- ⚠️ Core Audio tap IO-proc block MUST be `@convention(block) @Sendable`. The block is defined inside `@MainActor SystemAudioService.startCapture`, so without `@Sendable` Swift 6 infers MainActor isolation and emits an executor assertion at the block's entry. Core Audio runs the block on its own RT thread → `dispatch_assert_queue` fails → SIGTRAP on the first buffer (crash on Record). This was the libdispatch main-thread assertion the prior attempt blamed on `AVAssetWriter`; the real cause was isolation inheritance, fixed 2026-06-03. The `NSLock`-guarded `AVAudioFile` write on the RT thread is fine. Safety nets: live silence warning + audio-retention-on-empty. Ref insidegui/AudioCap for a known-good tap writer.
- Code signing required for TCC permissions
- Speech recognition permission and local SpeechTranscriber asset availability are preflighted before recording can start.
- Calendar meeting loading requires full access; write-only access should surface an upgrade-required state.
- Raw audio cleanup must permanently remove files, not move them to Trash.
- `MenuBarCoordinator.latestTranscriptURL` tracks the newest saved markdown file so the menu can expose "Open Latest Transcript" without adding a transcript browser.
- `SystemAudioService.stopCapture()` is `async throws` — callers must `try await`; throws `SystemAudioError.noAudioCaptured` when zero frames were written, and `.tapCreationFailed`/`.aggregateCreationFailed`/`.writeFailed` on Core Audio setup or file errors.
- For non-observed properties accessed in `deinit` of `@Observable` classes, prefer `@ObservationIgnored` plus `isolated deinit` over `nonisolated(unsafe)`.
- `TranscriptionService.transcribe()` uses a duration-scaled timeout (`max(300, duration×2 + 60)`; 1800s when duration is unreadable) via `withThrowingTaskGroup`; throws `TranscriptionError.timeout` if the pipeline stalls. The old fixed 300s cap false-failed long recordings.
- `SettingsStore.init(defaults:)` accepts a `UserDefaults` suite for test injection; production code uses `.standard` by default.
- Meeting Audio always captures system output and microphone into separate temporary tracks. `AudioMixingService` uses AVFoundation to combine them locally into one `.m4a` before SpeechTranscriber runs, then the component tracks and successful transcription input are permanently deleted. This captures both sides with speakers or headphones while preserving the Core Audio tap's lid-closed behavior. If system capture fails, the microphone track is transcribed with an explicit incomplete-capture warning.
- `SpeechAnalyzer` keep-alive: `_ = analyzer` must appear **after** the `for try await` loop, not before it. ARC determines lifetime by last-use; placing it before the loop lets the compiler drop the analyzer before the pipeline drains.
- `StorageService` records raw audio under a TokDown-owned temporary session folder, then writes only the final `.md` transcript to the selected folder. `cleanupTemporaryAudioFiles()` is called from `loadMeetings()` and only deletes `.m4a` files from TokDown temporary storage.

## Repo layout (2026-09-02)

One repo, two apps. The macOS menu bar app is the root Swift package (`swift build`).
The iOS app lives in `Apps/iOS/` (`cd Apps/iOS && xcodegen generate`, then build the
project); it arrived by subtree merge from tokdown-mobile with full history.
Next step: extract `Sources/TokDownKit` (formatter, transcription protocol, calendar and
settings cores) so both apps share it. Nothing is shared yet.
