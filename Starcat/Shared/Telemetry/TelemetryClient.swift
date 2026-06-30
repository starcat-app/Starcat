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

enum TelemetryClientError: Error {
    case invalidConfiguration
}

protocol TelemetryClient: Sendable {
    func track(_ event: TelemetryEvent) throws
}

struct NoopTelemetryClient: TelemetryClient {
    func track(_ event: TelemetryEvent) throws {}
}

final class SpyTelemetryClient: TelemetryClient, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TelemetryEvent] = []

    var events: [TelemetryEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func track(_ event: TelemetryEvent) throws {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}

struct ThrowingTelemetryClient: TelemetryClient {
    func track(_ event: TelemetryEvent) throws {
        throw TelemetryClientError.invalidConfiguration
    }
}
