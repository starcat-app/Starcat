//
//  TelemetryEvent.swift
//  Starcat
//
//  Anonymous telemetry event model.
//
//  Starcat is a local-first GitHub tool, so telemetry must be opt-in and
//  schema-limited. This file intentionally uses enums for event names and
//  property keys instead of raw dictionaries, so call sites cannot accidentally
//  send repository names, search text, notes, prompts, local paths, or secrets.
//

import Foundation

/// Allowlisted anonymous telemetry events.
enum TelemetryEventName: String, CaseIterable, Sendable {
    case appLaunched = "app_launched"
    case manageOpened = "manage_opened"
    case activityOpened = "activity_opened"
    case exploreOpened = "explore_opened"
    case searchPerformed = "search_performed"
    case repoDetailOpened = "repo_detail_opened"
    case readmeOpened = "readme_opened"
    case aiPanelOpened = "ai_panel_opened"
    case settingsOpened = "settings_opened"
    case syncStarted = "sync_started"
    case syncFinished = "sync_finished"
    case syncFailed = "sync_failed"
}

/// Allowlisted telemetry property keys.
enum TelemetryPropertyKey: String, Sendable {
    case durationBucket = "duration_bucket"
    case repoCountBucket = "repo_count_bucket"
    case result = "result"
    case source = "source"
}

/// Primitive value type accepted by Aptabase custom properties.
///
/// Aptabase only accepts strings and numbers for custom properties. Keeping that
/// constraint here makes all non-Aptabase call sites backend-agnostic.
enum TelemetryPropertyValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)

    var aptabaseValue: Any {
        switch self {
        case .string(let value): return value
        case .int(let value):    return value
        case .double(let value): return value
        }
    }
}

/// Anonymous telemetry event with schema-limited properties.
struct TelemetryEvent: Equatable, Sendable {
    let name: TelemetryEventName
    let properties: [TelemetryPropertyKey: TelemetryPropertyValue]

    init(
        _ name: TelemetryEventName,
        properties: [TelemetryPropertyKey: TelemetryPropertyValue] = [:]
    ) {
        self.name = name
        self.properties = properties
    }

    /// Converts allowlisted keys into the string dictionary expected by SDKs.
    var sdkProperties: [String: Any] {
        Dictionary(uniqueKeysWithValues: properties.map { key, value in
            (key.rawValue, value.aptabaseValue)
        })
    }
}

enum TelemetryBuckets {

    /// Coarse count buckets avoid uploading exact user library size.
    static func repoCountBucket(_ count: Int) -> String {
        switch count {
        case ..<100:      return "lt_100"
        case 100..<1_000: return "100_999"
        case 1_000..<5_000: return "1000_4999"
        case 5_000..<10_000: return "5000_9999"
        default:         return "gte_10000"
        }
    }

    /// Coarse duration buckets are enough for product analytics; detailed
    /// timings stay local in OSSignposter / Instruments.
    static func durationBucket(milliseconds: Int) -> String {
        switch milliseconds {
        case ..<100:      return "lt_100ms"
        case 100..<300:   return "100_299ms"
        case 300..<1_000: return "300_999ms"
        case 1_000..<3_000: return "1000_2999ms"
        default:          return "gte_3000ms"
        }
    }
}
