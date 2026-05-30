# CLAUDE.md — TokDown

macOS menu bar app: system audio → transcript markdown. ~1.6k app LOC, focused XCTest coverage, no deps.

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
- ⚠️ Core Audio tap re-attempt (2026-05-30) — UNVERIFIED on macOS 26. A prior attempt was abandoned because writing tap audio via `AVAssetWriter`/`AVAudioFile`/`ExtAudioFile` crashed identically with a libdispatch **main-thread** assertion. The current impl writes `AVAudioFile` inside the tap's Core Audio RT thread (`AudioDeviceCreateIOProcIDWithBlock` with a **nil queue**, not main) guarded by `NSLock`, which *should* dodge that assertion — but this has not been runtime-tested. If the crash recurs, this gotcha is why; ref insidegui/AudioCap for a known-good tap writer. Safety nets if the tap misbehaves: live silence warning + audio-retention-on-empty.
- Code signing required for TCC permissions
- Speech recognition permission and local SpeechTranscriber asset availability are preflighted before recording can start.
- Calendar meeting loading requires full access; write-only access should surface an upgrade-required state.
- Raw audio cleanup must permanently remove files, not move them to Trash.
- `MenuBarCoordinator.latestTranscriptURL` tracks the newest saved markdown file so the menu can expose "Open Latest Transcript" without adding a transcript browser.
- `SystemAudioService.stopCapture()` is `async throws` — callers must `try await`; throws `SystemAudioError.noAudioCaptured` when zero frames were written, and `.tapCreationFailed`/`.aggregateCreationFailed`/`.writeFailed` on Core Audio setup or file errors.
- For non-observed properties accessed in `deinit` of `@Observable` classes, prefer `@ObservationIgnored` plus `isolated deinit` over `nonisolated(unsafe)`.
- `TranscriptionService.transcribe()` uses a duration-scaled timeout (`max(300, duration×2 + 60)`; 1800s when duration is unreadable) via `withThrowingTaskGroup`; throws `TranscriptionError.timeout` if the pipeline stalls. The old fixed 300s cap false-failed long recordings.
- `SettingsStore.init(defaults:)` accepts a `UserDefaults` suite for test injection; production code uses `.standard` by default.
- `SystemAudioService` meters per-buffer peak on the IO-proc thread; `MenuBarCoordinator` polls `hasCapturedAudibleSignal()` and shows a live menu warning if a system-audio capture stays silent past an 8s grace. Optional mic fallback (setting) records the mic in parallel and is transcribed if the system transcript is empty.
- `SpeechAnalyzer` keep-alive: `_ = analyzer` must appear **after** the `for try await` loop, not before it. ARC determines lifetime by last-use; placing it before the loop lets the compiler drop the analyzer before the pipeline drains.
- `StorageService` records raw audio under a TokDown-owned temporary session folder, then writes only the final `.md` transcript to the selected folder. `cleanupTemporaryAudioFiles()` is called from `loadMeetings()` and only deletes `.m4a` files from TokDown temporary storage.
