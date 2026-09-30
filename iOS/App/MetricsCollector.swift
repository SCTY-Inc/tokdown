import Foundation
import MetricKit

/// Captures MetricKit payloads so shipped builds can be compared over time.
final class MetricsCollector: NSObject, MXMetricManagerSubscriber {

    override init() {
        super.init()
        MXMetricManager.shared.add(self)
    }

    deinit {
        MXMetricManager.shared.remove(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            let json = payload.jsonRepresentation()
            let message = "MetricKit payload received bytes=\(json.count)"
            DebugLog.write(message)
            PerformanceTrace.log(message)
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for _ in payloads {
            DebugLog.write("MetricKit diagnostic payload received")
        }
    }
}
