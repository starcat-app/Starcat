//
//  ExternalSearchRegistry.swift
//  Starcat
//
//  External Search Provider 注册表。
//
//  Registry 是设置层与调用层之间的边界：调用方只按 provider id 取
//  `ExternalSearchProvider`，不用知道 Tavily / Exa / Brave / AnySearch 的 Keychain
//  service id、匿名模式或初始化细节。
//

import Foundation

/// External Search Provider 工厂。
struct ExternalSearchRegistry: Sendable {
    private let settingsSnapshot: SettingsSnapshot
    private let session: URLSession?

    @MainActor
    init(settings: AppSettings, session: URLSession? = nil) {
        self.settingsSnapshot = SettingsSnapshot(settings: settings)
        self.session = session
    }

    init(settingsSnapshot: SettingsSnapshot, session: URLSession? = nil) {
        self.settingsSnapshot = settingsSnapshot
        self.session = session
    }

    func provider(for id: ExternalSearchProviderID) -> any ExternalSearchProvider {
        let providerSettings = settingsSnapshot.providerSettings[id]
            ?? ExternalSearchProviderSettings.defaultSettings(for: id)
        let apiKey = settingsSnapshot.apiKeys[id]
        switch id {
        case .anySearch:
            return AnySearchExternalSearchProvider(
                apiKey: apiKey,
                anonymous: providerSettings.anonymousMode,
                isEnabled: providerSettings.isEnabled
            )
        case .tavily:
            return TavilySearchProvider(apiKey: apiKey, isEnabled: providerSettings.isEnabled, session: session)
        case .exa:
            return ExaSearchProvider(apiKey: apiKey, isEnabled: providerSettings.isEnabled, session: session)
        case .braveLLMContext:
            return BraveLLMContextSearchProvider(apiKey: apiKey, isEnabled: providerSettings.isEnabled, session: session)
        case .firecrawl:
            return FirecrawlSearchProvider(
                apiKey: apiKey,
                isEnabled: providerSettings.isEnabled,
                anonymous: providerSettings.anonymousMode,
                fetchFullText: providerSettings.fetchFullText,
                session: session
            )
        }
    }

    func usableProviderIDs(includeUnverified: Bool = false) -> [ExternalSearchProviderID] {
        ExternalSearchProviderID.allCases.filter { id in
            let providerSettings = settingsSnapshot.providerSettings[id]
                ?? ExternalSearchProviderSettings.defaultSettings(for: id)
            guard providerSettings.isEnabled else { return false }
            if id.supportsAnonymous, providerSettings.anonymousMode { return true }
            if includeUnverified { return settingsSnapshot.apiKeys[id]?.isEmpty == false }
            return settingsSnapshot.apiKeys[id]?.isEmpty == false && providerSettings.hasVerifiedCredential
        }
    }

    /// Registry 使用的不可变设置快照。
    ///
    /// `AppSettings` 是 `@Observable` 主线程对象，不能把它直接丢进后台搜索任务里。
    /// 快照只包含 Provider 构造所需的本机状态，避免并发任务读写设置对象。
    struct SettingsSnapshot: Sendable {
        let providerSettings: [ExternalSearchProviderID: ExternalSearchProviderSettings]
        let apiKeys: [ExternalSearchProviderID: String]

        @MainActor
        init(settings: AppSettings) {
            self.providerSettings = settings.externalSearchProviderSettings
            self.apiKeys = Dictionary(uniqueKeysWithValues: ExternalSearchProviderID.allCases.compactMap { id in
                guard let key = settings.externalSearchAPIKey(for: id), !key.isEmpty else { return nil }
                return (id, key)
            })
        }

        init(
            providerSettings: [ExternalSearchProviderID: ExternalSearchProviderSettings],
            apiKeys: [ExternalSearchProviderID: String]
        ) {
            self.providerSettings = providerSettings
            self.apiKeys = apiKeys
        }
    }
}
