import Foundation
import os

/// Lightweight signpost and logging helpers for battery/performance measurement.
enum PerformanceTrace {

    private static let logger = Logger(subsystem: "com.amadad.tokdown", category: "performance")
    private static let signposter = OSSignposter(logger: logger)

    static func beginInterval(_ name: StaticString, detail: String = "") -> OSSignpostIntervalState {
        if detail.isEmpty {
            return signposter.beginInterval(name)
        }
        return signposter.beginInterval(name, "\(detail, privacy: .public)")
    }

    static func endInterval(_ name: StaticString, state: OSSignpostIntervalState, detail: String = "") {
        if detail.isEmpty {
            signposter.endInterval(name, state)
        } else {
            signposter.endInterval(name, state, "\(detail, privacy: .public)")
        }
    }

    static func emitEvent(_ name: StaticString, detail: String = "") {
        if detail.isEmpty {
            signposter.emitEvent(name)
        } else {
            signposter.emitEvent(name, "\(detail, privacy: .public)")
        }
    }

    static func log(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }
}
