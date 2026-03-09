# AGENTS.md — Echo Log

## Purpose
macOS menu bar app: system audio → transcript markdown. No audio files kept.

## Quick Reference

| Command | What |
|---|---|
| `bash scripts/build-app.sh debug` | Build + sign + bundle |
| `open MenuBarRecorder.app` | Launch |
| `pkill -x MenuBarRecorder` | Kill |

## Architecture

3-state machine: `idle → recording → transcribing → idle`

| File | Role | Lines |
|---|---|---|
| MenuBarCoordinator.swift | Orchestrator, state machine, markdown output | 239 |
| SystemAudioService.swift | ScreenCaptureKit → AVAssetWriter (.m4a) | 106 |
| MenuBarViews.swift | Menu bar content + Settings window | 105 |
| TranscriptionService.swift | SFSpeechRecognizer file transcription | 67 |
| CalendarService.swift | EventKit upcoming meetings | 61 |
| AppModels.swift | RecordingState, AudioSource, AppSettings, UpcomingMeeting, TranscriptLine | 56 |
| RecordingService.swift | AVAudioRecorder (mic fallback) | 48 |
| SettingsStore.swift | UserDefaults persistence (folder + audio source) | 47 |
| StorageService.swift | File I/O, path generation | 44 |
| MenuBarRecorder.swift | @main entry, Scene setup | 26 |

## Key Decisions

- **System audio via ScreenCaptureKit** — captures all app audio regardless of output device. Triggers macOS purple recording indicator (unavoidable).
- **Apple Speech only** — on-device SFSpeechRecognizer. No Whisper, no API keys. Good enough for meeting transcripts.
- **Audio always deleted** — only `.md` files saved. Git-friendly output.
- **Flat output** — `~/Documents/Transcripts/YYYY-MM-DD_HH-mm_Title.md`. No subfolders.
- **Ad-hoc or Apple Development signing** — build script auto-detects signing identity from keychain.
- **No external dependencies** — pure Apple frameworks.

## Permissions (entitlements + Info.plist)

| Permission | Why | Entitlement |
|---|---|---|
| Screen Recording | System audio capture | `com.apple.security.screen-capture` |
| Microphone | Mic recording mode | `com.apple.security.device.audio-input` |
| Calendar | Meeting list | `com.apple.security.personal-information.calendars` |
| Speech Recognition | Transcription | (Info.plist only) |

## Gotchas

- **Swift 6 strict concurrency** — all permission request callbacks must avoid `Task { @MainActor in }` inside completion handlers. Use `DispatchQueue.global().async` wrapper to avoid dispatch assertion crashes on macOS Tahoe.
- **ScreenCaptureKit requires video config** — even for audio-only, must set width/height/framerate. We use 2x2 @ 1fps.
- **MenuBarExtra with `.menu` style** — SwiftUI views become NSMenuItems. VStack/padding/frame mostly ignored.
- **LSUIElement=true** — no dock icon. Settings window needs `NSApp.activate(ignoringOtherApps: true)` to come to front.
- **TCC + code signing** — unsigned/ad-hoc apps may silently fail permission requests. Build script auto-signs with first available identity.

## Transcript Format

```markdown
# Meeting Title

2026-03-09 14:00–14:30

[00:05] First chunk of transcribed text grouped by ~5s windows.

[00:10] Next chunk continues here with natural grouping.
```

## Settings (UserDefaults)

Only two settings persisted:
- `saveFolderPath` — where transcripts go (default: `~/Documents/Transcripts/`)
- `audioSource` — `systemAudio` (default) or `microphone`
