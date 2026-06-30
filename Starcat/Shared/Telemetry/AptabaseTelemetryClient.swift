//
//  AptabaseTelemetryClient.swift
//  Starcat
//
//  Aptabase-backed anonymous telemetry client.
//
//  The concrete SDK stays isolated in this adapter. Product code only sees
//  `TelemetryManager`, which keeps privacy gates and event schema enforcement
//  independent from the chosen analytics backend.
//

import Foundation
import Aptabase

struct AptabaseTelemetryClient: TelemetryClient {

    init(appKey: String) {
        Aptabase.shared.initialize(appKey: appKey)
    }

    func track(_ event: TelemetryEvent) throws {
        Aptabase.shared.trackEvent(event.name.rawValue, with: event.sdkProperties)
    }
}
