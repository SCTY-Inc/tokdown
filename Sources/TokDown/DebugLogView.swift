import SwiftUI
import UIKit

/// Displays the contents of Documents/debug.log for field debugging.
/// Only meaningful in DEBUG builds where DebugLog.write() is active.
struct DebugLogView: View {

    @State private var logText: String = ""
    @State private var copyLabel = "Copy"

    private var logURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("debug.log")
    }

    var body: some View {
        Group {
            if logText.isEmpty {
                ContentUnavailableView(
                    "No Log Entries",
                    systemImage: "doc.text",
                    description: Text("Debug events appear here during a recording session.")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(logText)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .id("logContent")
                    }
                    .onAppear {
                        proxy.scrollTo("logContent", anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle("Debug Log")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(copyLabel) {
                    UIPasteboard.general.string = logText
                    copyLabel = "Copied"
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copyLabel = "Copy"
                    }
                }
                .disabled(logText.isEmpty)

                Button("Refresh") { loadLog() }
            }
        }
        .onAppear { loadLog() }
    }

    private func loadLog() {
        guard let url = logURL,
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else {
            logText = ""
            return
        }
        logText = text
    }
}
