import SwiftUI
import AppKit

enum MenuBarIconBadge: Equatable {
    case none
    case recording
    case transcribing
}

struct MenuBarIconPresentation: Equatable {
    let accessibilityLabel: String
    let badge: MenuBarIconBadge

    static func forState(_ state: RecordingState) -> MenuBarIconPresentation {
        switch state {
        case .idle:
            MenuBarIconPresentation(accessibilityLabel: "TokDown", badge: .none)
        case .recording:
            MenuBarIconPresentation(accessibilityLabel: "TokDown recording", badge: .recording)
        case .transcribing:
            MenuBarIconPresentation(accessibilityLabel: "TokDown transcribing", badge: .transcribing)
        }
    }
}

struct MenuBarIconView: View {
    let state: RecordingState
    @State private var animPhase: Bool = false

    private var presentation: MenuBarIconPresentation {
        .forState(state)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: MenuBarTemplateImage.branded)
                .renderingMode(.template)
                .interpolation(.high)
                .frame(width: 18, height: 14)

            badgeView
                .offset(x: 0.5, y: -0.5)
        }
        .frame(width: 18, height: 14)
        .accessibilityLabel(Text(presentation.accessibilityLabel))
    }

    @ViewBuilder
    private var badgeView: some View {
        switch presentation.badge {
        case .none:
            EmptyView()
        case .recording:
            Circle()
                .fill(.red)
                .frame(width: 5.5, height: 5.5)
        case .transcribing:
            HStack(spacing: 1.2) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(.primary)
                        .frame(width: 1.8, height: 1.8)
                        .opacity(animPhase ? 1.0 : 0.3)
                }
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    animPhase = true
                }
            }
            .onDisappear { animPhase = false }
        }
    }
}

private enum MenuBarTemplateImage {
    static let branded: NSImage = {
        let canvasSize = NSSize(width: 18, height: 14)
        let image = NSImage(size: canvasSize)

        image.lockFocus()
        defer { image.unlockFocus() }

        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.black.setFill()

        let barWidth: CGFloat = 2.8
        let barGap: CGFloat = 1.15
        let barHeights: [CGFloat] = [7.0, 10.4, 13.2, 10.4]
        let totalWidth = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * barGap
        let startX = round((canvasSize.width - totalWidth) / 2)
        let baseline: CGFloat = 0.35
        let cornerRadius = barWidth / 2

        for (index, height) in barHeights.enumerated() {
            let x = startX + CGFloat(index) * (barWidth + barGap)
            let barRect = NSRect(x: x, y: baseline, width: barWidth, height: height)
            let barPath = NSBezierPath(roundedRect: barRect, xRadius: cornerRadius, yRadius: cornerRadius)
            barPath.fill()
        }

        image.isTemplate = true
        return image
    }()
}
