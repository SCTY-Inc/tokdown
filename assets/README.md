# Branding Assets

Starter branding assets for TokDown.

## Included

- `Sources/TokDown/Resources/TokDownIcon.svg` — starter app icon concept source
- `Sources/TokDown/MenuBarIconView.swift` — code-driven custom menu bar icon with idle, recording, and transcribing states

## Notes

The menu bar icon is drawn in SwiftUI for crisp rendering and easy state changes.

The app icon SVG is a starter concept for refinement into a proper macOS `.icns` set later.

Recommended next step for the app icon:
1. refine the SVG visually
2. export PNGs at standard macOS icon sizes
3. generate `TokDown.icns`
4. bundle it into the app resources and point `Info.plist` to it
