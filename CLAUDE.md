# CLAUDE.md — TokDown

macOS menu bar app: system audio → transcript markdown. ~1.6k app LOC, focused XCTest coverage, no deps.

## Build & Run
```bash
bash scripts/build-app.sh debug && open TokDown.app
```

## Structure
3 states: idle → recording → transcribing. See AGENTS.md for full architecture.

## Output
`~/Documents/Transcripts/YYYY-MM-DD_HH-mm_Title[-2].md` — date-first filenames, collision-safe suffixing, YAML front matter + markdown body, no audio files, git-friendly.

## Gotchas
- Swift 6 concurrency: no `Task { @MainActor in }` inside completion handlers
- Uses `@Observable` — not `ObservableObject`. Don't introduce `@Published`, `@StateObject`, or `@EnvironmentObject`.
- ScreenCaptureKit needs video config even for audio-only (2x2 @ 1fps), and TokDown registers both screen + audio outputs so system-audio sessions don't silently run with zero captured samples.
- Core Audio Taps migration blocked by libdispatch main-thread assertion crash on macOS 26 — tried AVAssetWriter, AVAudioFile, ExtAudioFile, all crash identically. Needs Xcode thread sanitizer debugging. Track via AudioCap (insidegui/AudioCap) patterns.
- Code signing required for TCC permissions
- Speech recognition permission and local SpeechTranscriber asset availability are preflighted before recording can start.
- Calendar meeting loading requires full access; write-only access should surface an upgrade-required state.
- Raw audio cleanup must permanently remove files, not move them to Trash.
- `SystemAudioService.stopCapture()` is `async throws` — callers must `try await`; throws `SystemAudioError.noAudioCaptured` when no system-audio samples were appended, and `SystemAudioError.writeFailed` if `AVAssetWriter` finishes in `.failed` state.
- For non-observed properties accessed in `deinit` of `@Observable` classes, prefer `@ObservationIgnored` plus `isolated deinit` over `nonisolated(unsafe)`.
- `TranscriptionService.transcribe()` has a 300-second timeout via `withThrowingTaskGroup`; throws `TranscriptionError.timeout` if the speech pipeline stalls.
- `SettingsStore.init(defaults:)` accepts a `UserDefaults` suite for test injection; production code uses `.standard` by default.
- `SystemAudioService` prefers the hovered display, then `NSScreen.main`, instead of blindly using the first ScreenCaptureKit display; arbitrary display selection can produce empty system-audio sessions when output routes move around.
- `SpeechAnalyzer` keep-alive: `_ = analyzer` must appear **after** the `for try await` loop, not before it. ARC determines lifetime by last-use; placing it before the loop lets the compiler drop the analyzer before the pipeline drains.
- `StorageService` records raw audio under a TokDown-owned temporary session folder, then writes only the final `.md` transcript to the selected folder. `cleanupTemporaryAudioFiles()` is called from `loadMeetings()` and only deletes `.m4a` files from TokDown temporary storage.
