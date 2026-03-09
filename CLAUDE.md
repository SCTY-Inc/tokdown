# CLAUDE.md — Echo Log

macOS menu bar app: system audio → transcript markdown. ~800 LOC, no deps.

## Build & Run
```bash
bash scripts/build-app.sh debug && open MenuBarRecorder.app
```

## Structure
3 states: idle → recording → transcribing. See AGENTS.md for full architecture.

## Output
`~/Documents/Transcripts/YYYY-MM-DD_HH-mm_Title.md` — flat, no audio files, git-friendly.

## Gotchas
- Swift 6 concurrency: no `Task { @MainActor in }` inside completion handlers
- ScreenCaptureKit needs video config even for audio-only (2x2 @ 1fps)
- Code signing required for TCC permissions
