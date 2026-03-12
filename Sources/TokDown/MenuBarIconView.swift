import SwiftUI

struct MenuBarIconView: View {
    let state: RecordingState

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: 13, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .frame(width: 18, height: 14)
            .accessibilityLabel(accessibilityLabel)
    }

    private var symbolName: String {
        switch state {
        case .idle: "waveform"
        case .recording: "record.circle"
        case .transcribing: "ellipsis.circle"
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .idle: "TokDown"
        case .recording: "TokDown recording"
        case .transcribing: "TokDown transcribing"
        }
    }
}
