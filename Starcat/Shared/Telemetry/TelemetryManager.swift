//
//  TelemetryManager.swift
//  Starcat
//
//  Opt-in anonymous telemetry coordinator.
//
//  The manager owns the runtime policy: telemetry is disabled in tests, disabled
//  when the user opt-in switch is off, and disabled when no backend key is
//  configured. Keeping those checks here prevents each feature from inventing
//  its own privacy gate.
//

import Foundation

@MainActor
@Observable
final class TelemetryManager {

    private let settings: AppSettings
    private var client: any TelemetryClient
    private let ignoresTestEnvironmentForUnitTests: Bool

    private(set) var isBackendConfigured: Bool

    init(
        settings: AppSettings,
        client: any TelemetryClient = NoopTelemetryClient(),
        isBackendConfigured: Bool = false,
        ignoresTestEnvironmentForUnitTests: Bool = false
    ) {
        self.settings = settings
        self.client = client
        self.isBackendConfigured = isBackendConfigured
        self.ignoresTestEnvironmentForUnitTests = ignoresTestEnvironmentForUnitTests
    }

    /// Installs a concrete backend after `AppSettings` is available.
    ///
    /// Tests always stay no-op even if a developer machine has a real
    /// `Secrets.xcconfig`, because test hosts must not send network telemetry.
    func configure(client: any TelemetryClient, isBackendConfigured: Bool) {
        guard !TestEnvironment.isRunning else {
            self.client = NoopTelemetryClient()
            self.isBackendConfigured = false
            return
        }
        self.client = client
        self.isBackendConfigured = isBackendConfigured
    }

    func track(_ name: TelemetryEventName, properties: [TelemetryPropertyKey: TelemetryPropertyValue] = [:]) {
        track(TelemetryEvent(name, properties: properties))
    }

    func track(_ event: TelemetryEvent) {
        guard canSend else { return }
        do {
            try client.track(event)
        } catch {
            // Telemetry must never affect product flows or surface user-visible
            // errors. Backend misconfiguration and upload failures stay in the
            // developer log only; users can continue using Starcat normally.
            AppLog.general.debug("Telemetry event dropped: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var canSend: Bool {
        settings.telemetryEnabled
            && isBackendConfigured
            && (!TestEnvironment.isRunning || ignoresTestEnvironmentForUnitTests)
    }
}

enum TelemetryConfiguration {

    /// Aptabase app key injected via xcconfig → Info.plist.
    ///
    /// Empty string means "backend intentionally not configured"; App still
    /// builds and simply keeps telemetry no-op.
    static var aptabaseAppKey: String? {
        guard let raw = Bundle.main.infoDictionary?["STARCAT_APTABASE_APP_KEY"] as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isValidAptabaseAppKey(trimmed) else { return nil }
        return trimmed
    }

    /// Aptabase keys are shaped as `<prefix>-<region>-<project>`.
    ///
    /// We validate before calling the SDK so invalid local configuration does
    /// not make the SDK print the raw key in debug logs. Supported regions match
    /// Aptabase Swift SDK 0.3.x hosts.
    static func isValidAptabaseAppKey(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        guard ["US", "EU"].contains(String(parts[1])) else { return false }
        return parts.allSatisfy { !$0.isEmpty }
    }
}
