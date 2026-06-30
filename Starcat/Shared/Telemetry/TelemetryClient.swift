//
//  TelemetryClient.swift
//  Starcat
//
//  Telemetry backend abstraction.
//
//  Business code talks to `TelemetryManager`, which then fans out to a concrete
//  client. This keeps Aptabase replaceable and gives tests a small spy surface
//  without importing the third-party SDK.
//

import Foundation

protocol TelemetryClient: Sendable {
    func track(_ event: TelemetryEvent)
}

struct NoopTelemetryClient: TelemetryClient {
    func track(_ event: TelemetryEvent) {}
}

final class SpyTelemetryClient: TelemetryClient, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TelemetryEvent] = []

    var events: [TelemetryEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func track(_ event: TelemetryEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}
