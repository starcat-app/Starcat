//
//  MetricKitReporter.swift
//  Starcat
//
//  MetricKit subscriber for system-provided performance and diagnostic payloads.
//
//  First version deliberately records only compact local summaries into
//  `DiagnosticLogStore`. Raw MetricKit JSON can be large and may include details
//  that should be reviewed before any remote upload policy exists.
//

import Foundation
import MetricKit

final class MetricKitReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {

    static let shared = MetricKitReporter()

    private let lock = NSLock()
    private var started = false

    private override init() {
        super.init()
    }

    func start() {
        guard !TestEnvironment.isRunning else { return }

        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        MXMetricManager.shared.add(self)
        started = true
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard started else { return }
        MXMetricManager.shared.remove(self)
        started = false
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            record(
                operation: "metricPayload",
                payloadType: "metric",
                payloadSize: payload.jsonRepresentation().count
            )
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            record(
                operation: "diagnosticPayload",
                payloadType: "diagnostic",
                payloadSize: payload.jsonRepresentation().count
            )
        }
    }

    private func record(operation: String, payloadType: String, payloadSize: Int) {
        DiagnosticLogStore.record(
            level: .info,
            category: "telemetry",
            operation: operation,
            message: "MetricKit payload received",
            service: "MetricKit",
            context: [
                "payloadType": payloadType,
                "payloadSizeBytes": String(payloadSize)
            ]
        )
    }
}
