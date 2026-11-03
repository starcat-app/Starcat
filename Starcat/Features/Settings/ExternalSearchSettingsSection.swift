//
//  ExternalSearchSettingsSection.swift
//  Starcat
//
//  设置 → 检索 → 联网搜索：搜索服务配置。
//
//  模块级说明：
//  - 全局搜索、AI 外部上下文与五家 Provider 分别使用同级原生 Section。
//  - Provider 元数据继续写入 AppSettings，API Key 继续走既有安全存储。
//  - 仅调整信息架构，不改变匿名模式、Pro 聚合能力或凭据验证语义。
//

import SwiftUI

/// 联网搜索设置 Section，可直接嵌入主设置的 grouped Form。
struct ExternalSearchSettingsSection: View {

    @Environment(AppSettings.self) private var settings
    @Environment(\.locale) private var locale

    @State private var isExternalContextAdvancedExpanded = false
    @State private var externalSearchAPIKeys: [ExternalSearchProviderID: String] = [:]
    @State private var expandedExternalSearchProviders: Set<ExternalSearchProviderID> = []
    @State private var expandedExternalSearchTechnicalDetails: Set<ExternalSearchProviderID> = []
    @State private var externalSearchAPIKeyTestStates: [ExternalSearchProviderID: APIKeyTestState] = [:]
    @State private var externalSearchTestRevisions: [ExternalSearchProviderID: UUID] = [:]
    /// 仅记录用户尝试启用但尚未验证的服务商，不提前写入启用状态或凭据。
    @State private var providersRequiringVerification: Set<ExternalSearchProviderID> = []

    var body: some View {
        Group {
            introductionSection
            globalSearchSection
            externalContextSection
            ForEach(ExternalSearchProviderID.allCases) { provider in
                providerSection(provider)
            }
        }
        .task {
            loadExternalSearchAPIKeys()
        }
        .onDisappear {
            for provider in ExternalSearchProviderID.allCases { invalidateTest(provider) }
        }
    }

    /// 沿用翻译页的原生介绍卡片；分组表面和边距仍由宿主 grouped Form 管理。
    private var introductionSection: some View {
        Section {
            HStack(spacing: 16) {
                Image(systemName: "globe")
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)

                Divider()
                    .frame(height: 48)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("settings.navigation.item.webSearch")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .help(Text("settings.navigation.item.webSearch"))
                    Text("settings.externalSearch.copy.introduction")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(Text("settings.externalSearch.copy.introduction"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }

    private var globalSearchSection: some View {
        @Bindable var settings = settings
        return Section {
            Picker("settings.externalSearch.copy.defaultProvider", selection: $settings.externalSearchDefaultProvider) {
                ForEach(ExternalSearchProviderID.allCases) { provider in
                    Text(verbatim: provider.displayName).tag(provider)
                }
            }
            selectionFeedback(for: settings.externalSearchDefaultProvider)

            Toggle("settings.externalSearch.copy.includeWebInAll", isOn: $settings.externalSearchIncludeInAll)
        } header: {
            SettingsSectionHeader("settings.externalSearch.layout.global", systemImage: "magnifyingglass")
        }
    }

    private var externalContextSection: some View {
        @Bindable var settings = settings
        return Section {
            centeredToggle(
                "settings.externalSearch.copy.aiContext",
                description: "settings.externalSearch.copy.aiContextDescription",
                isOn: $settings.externalContextEnabled
            )
            Picker("settings.externalSearch.copy.contextProvider", selection: $settings.externalContextProviderSelection) {
                Text("settings.externalSearch.contextProvider.automatic").tag(ExternalContextProviderSelection.automatic)
                ForEach(ExternalSearchProviderID.allCases) { provider in
                    Text(verbatim: provider.displayName).tag(ExternalContextProviderSelection.provider(provider))
                }
            }
            selectionFeedback(for: settings.externalContextProviderSelection.explicitProviderID)

            DisclosureGroup(isExpanded: $isExternalContextAdvancedExpanded) {
                externalContextAdvancedControls
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.externalSearch.layout.advanced")
                        .lineLimit(1)
                        .help(Text("settings.externalSearch.layout.advanced"))
                    Text(verbatim: advancedRulesSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(advancedRulesSummary)
                }
            }
            .disclosureGroupStyle(SettingsDisclosureGroupStyle(
                accessibilityLabel: Text("settings.externalSearch.layout.advanced"),
                accessibilityHint: Text(verbatim: advancedRulesSummary)
            ))
        } header: {
            SettingsSectionHeader("settings.externalSearch.layout.context", systemImage: "sparkles")
        }
    }

    /// 折叠只影响展示；Pro 门控和私有仓库开关的依赖关系沿用现有绑定。
    private var externalContextAdvancedControls: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 12) {
            Divider()
            centeredToggle(
                "settings.externalSearch.aggregate",
                description: "settings.externalSearch.copy.aggregateDescription",
                isOn: aggregateExternalContextBinding,
                showsPro: !settings.isProUser
            )
            .disabled(!settings.isProUser)

            Divider()
            centeredToggle(
                "settings.externalSearch.copy.allowPrivateContext",
                description: "settings.externalSearch.copy.privateDescription",
                isOn: $settings.externalSearchAllowPrivateRepos
            )
            .disabled(!settings.externalContextEnabled)

            Divider()
            Text(String(format: String.l10n("settings.externalSearch.copy.priorityFormat"),
                        locale: locale,
                        ExternalSearchProviderID.automaticContextPriority.map(\.displayName).joined(separator: " → ")))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Form 的原生 Toggle 默认按标题对齐；显式居中布局让开关对齐整个双行说明块。
    private func centeredToggle(
        _ title: LocalizedStringKey,
        description: LocalizedStringKey,
        isOn: Binding<Bool>,
        showsPro: Bool = false
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    if showsPro {
                        Text(verbatim: "Pro")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text(title))
                .accessibilityHint(Text(description))
        }
    }

    private var advancedRulesSummary: String {
        [
            String.l10n(settings.aggregateExternalContextSearchEnabled
                        ? "settings.externalSearch.layout.aggregateOn" : "settings.externalSearch.layout.aggregateOff"),
            String.l10n(settings.externalSearchAllowPrivateRepos
                        ? "settings.externalSearch.layout.privateAllowed" : "settings.externalSearch.layout.publicOnly")
        ].joined(separator: " · ")
    }

    /// 五家服务商都是同级 Section；状态与启用开关常驻，连接编辑器各自独立折叠。
    private func providerSection(_ provider: ExternalSearchProviderID) -> some View {
        Section {
            HStack(alignment: .center, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text("settings.externalSearch.provider.enable")
                        Spacer(minLength: 8)
                        providerStatus(provider)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.externalSearch.provider.enable")
                        providerStatus(provider)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("settings.externalSearch.provider.enable", isOn: providerEnabledBinding(provider))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text(String(format: String.l10n("settings.externalSearch.provider.enableFormat"), locale: locale, provider.displayName)))
            }

            DisclosureGroup(isExpanded: providerExpansionBinding(provider)) {
                providerConnectionControls(provider)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.externalSearch.layout.connection")
                        .lineLimit(1)
                        .help(Text("settings.externalSearch.layout.connection"))
                    Text(providerCredentialStateKey(provider))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disclosureGroupStyle(SettingsDisclosureGroupStyle(
                accessibilityLabel: Text("settings.externalSearch.layout.connection"),
                accessibilityHint: Text(verbatim: provider.displayName)
            ))
        } header: {
            SettingsSectionHeader(verbatim: provider.displayName) {
                ExternalSearchProviderIcon(provider: provider, size: 13)
            }
        }
    }

    private func providerExpansionBinding(_ provider: ExternalSearchProviderID) -> Binding<Bool> {
        Binding(
            get: { expandedExternalSearchProviders.contains(provider) },
            set: { expanded in
                if expanded { expandedExternalSearchProviders.insert(provider) }
                else { expandedExternalSearchProviders.remove(provider) }
            }
        )
    }

    /// 状态只读取本机配置与已有测试结果，不在进入页面或展开配置时发起网络检查。
    @ViewBuilder
    private func providerStatus(_ provider: ExternalSearchProviderID) -> some View {
        if externalSearchAPIKeyTestStates[provider] == .testing {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("settings.externalSearch.layout.testing")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if case .failed = externalSearchAPIKeyTestStates[provider] {
            Label("settings.externalSearch.layout.failed", systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
        } else if externalSearchAPIKeyTestStates[provider] == .saveFailed {
            Label("settings.externalSearch.apiKey.saveFailed", systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
        } else if !settings.externalSearchSettings(for: provider).isEnabled {
            Text("settings.externalSearch.layout.disabled")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label(providerCredentialStateKey(provider), systemImage: canToggleProviderOn(provider) ? "checkmark.circle" : "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(canToggleProviderOn(provider) ? Color.green : Color.orange)
        }
    }

    private func providerCredentialStateKey(_ provider: ExternalSearchProviderID) -> LocalizedStringKey {
        let configuration = settings.externalSearchSettings(for: provider)
        if provider.supportsAnonymous, configuration.anonymousMode {
            return "settings.externalSearch.layout.anonymous"
        }
        if canToggleProviderOn(provider) { return "settings.externalSearch.layout.verified" }
        return apiKeyDraft(for: provider).isEmpty
            ? "settings.externalSearch.layout.missingKey" : "settings.externalSearch.layout.unverified"
    }

    /// 可用性提示复用现有凭据判定与自动优先级，两个 Picker 的存储仍完全独立。
    @ViewBuilder
    private func selectionFeedback(for explicitProvider: ExternalSearchProviderID?) -> some View {
        let selected = explicitProvider ?? ExternalSearchProviderID.automaticContextPriority.first {
            settings.externalSearchSettings(for: $0).isEnabled && canToggleProviderOn($0)
        }
        if let selected, settings.externalSearchSettings(for: selected).isEnabled, canToggleProviderOn(selected) {
            Label {
                Text(String(format: String.l10n(explicitProvider == nil
                                               ? "settings.externalSearch.copy.automaticFormat"
                                               : "settings.externalSearch.copy.availableFormat"), locale: locale, selected.displayName))
            } icon: {
                Image(systemName: "checkmark.circle")
            }
            .font(.caption)
            .foregroundStyle(.green)
        } else if let explicitProvider {
            Label {
                Text(String(format: String.l10n("settings.externalSearch.copy.unavailableFormat"),
                            locale: locale, explicitProvider.displayName))
            } icon: {
                Image(systemName: "exclamationmark.circle")
            }
            .font(.caption)
            .foregroundStyle(.orange)
        } else {
            Label("settings.externalSearch.copy.noneAvailable", systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func providerConnectionControls(_ provider: ExternalSearchProviderID) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            if provider.supportsAnonymous {
                centeredToggle(
                    "settings.externalSearch.copy.anonymous",
                    description: "settings.externalSearch.copy.anonymousDescription",
                    isOn: providerAnonymousBinding(provider)
                )
                .disabled(!settings.externalSearchSettings(for: provider).isEnabled)
            }

            if !provider.supportsAnonymous || !settings.externalSearchSettings(for: provider).anonymousMode {
                if provider.supportsAnonymous { Divider() }
                providerAPIKeyField(provider)
            }

            if provider == .firecrawl {
                Divider()
                centeredToggle(
                    "settings.externalSearch.copy.fullText",
                    description: "settings.externalSearch.copy.fullTextDescription",
                    isOn: providerFetchFullTextBinding(provider)
                )
                .disabled(!settings.externalSearchSettings(for: provider).isEnabled)
            }

            // 引导只出现在尚未测试时；失败后由具体错误替代，避免两条提示争抢注意力。
            if providersRequiringVerification.contains(provider),
               !canToggleProviderOn(provider),
               (externalSearchAPIKeyTestStates[provider] ?? .idle) == .idle {
                let guidanceKey: LocalizedStringKey = apiKeyDraft(for: provider).isEmpty
                    ? "settings.externalSearch.copy.verifyBeforeEnabling"
                    : "settings.externalSearch.copy.testBeforeEnabling"
                Divider()
                Label(guidanceKey, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            externalSearchAPIKeyTestFeedback(provider)

            Divider()
            // 错误摘要与操作同排；长错误在左侧换行，按钮保持固有宽度与右对齐。
            HStack(alignment: .center, spacing: 8) {
                externalSearchAPIKeySummary(provider)
                Spacer(minLength: 8)
                Link("settings.connection.getAPIKey", destination: externalSearchAPIKeyURL(for: provider))
                    .font(.caption)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Button {
                    testExternalSearchAPIKey(provider)
                } label: {
                    Text("settings.connection.testAndSave")
                }
                // 折叠区域内显式使用设置行正文，避免按钮继承容器的强调字号或字重。
                .font(.body)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .fixedSize()
                .disabled(!canTestExternalSearchKey(provider))
            }
        }
    }

    private func providerAPIKeyField(_ provider: ExternalSearchProviderID) -> some View {
        SettingsAPIKeyField(
            title: "settings.externalSearch.apiKey", text: apiKeyBinding(provider),
            prompt: Text(String(format: String.l10n("settings.externalSearch.apiKey.placeholderFormat"), provider.displayName))
        )
        .accessibilityLabel(Text(String(format: String.l10n("settings.externalSearch.apiKey.accessibilityFormat"), provider.displayName)))
    }

    private var aggregateExternalContextBinding: Binding<Bool> {
        Binding(
            get: { settings.aggregateExternalContextSearchEnabled },
            set: { settings.aggregateExternalContextSearchEnabled = $0 }
        )
    }

    private func providerEnabledBinding(_ provider: ExternalSearchProviderID) -> Binding<Bool> {
        Binding(
            get: { settings.externalSearchSettings(for: provider).isEnabled },
            set: { newValue in
                var providerSettings = settings.externalSearchSettings(for: provider)
                // 未验证时只展开配置和引导；测试成功后仍由既有 tester 保存凭据并启用。
                // 关闭不依赖凭据有效性，避免已启用服务商在验证失效后无法关闭。
                guard !newValue || canToggleProviderOn(provider) else {
                    providersRequiringVerification.insert(provider)
                    expandedExternalSearchProviders.insert(provider)
                    return
                }
                providersRequiringVerification.remove(provider)
                invalidateTest(provider)
                providerSettings.isEnabled = newValue
                settings.setExternalSearchSettings(providerSettings, for: provider)
            }
        )
    }

    private func providerAnonymousBinding(_ provider: ExternalSearchProviderID) -> Binding<Bool> {
        Binding(
            get: { settings.externalSearchSettings(for: provider).anonymousMode },
            set: { newValue in
                guard settings.externalSearchSettings(for: provider).anonymousMode != newValue else { return }
                invalidateTest(provider)
                var providerSettings = settings.externalSearchSettings(for: provider)
                providerSettings.anonymousMode = newValue
                settings.setExternalSearchSettings(providerSettings, for: provider)
            }
        )
    }

    private func providerFetchFullTextBinding(_ provider: ExternalSearchProviderID) -> Binding<Bool> {
        Binding(
            get: { settings.externalSearchSettings(for: provider).fetchFullText },
            set: { newValue in
                var providerSettings = settings.externalSearchSettings(for: provider)
                providerSettings.fetchFullText = newValue
                settings.setExternalSearchSettings(providerSettings, for: provider)
            }
        )
    }

    private func apiKeyBinding(_ provider: ExternalSearchProviderID) -> Binding<String> {
        Binding(
            get: { externalSearchAPIKeys[provider] ?? "" },
            set: { newValue in
                guard externalSearchAPIKeys[provider] != newValue else { return }
                externalSearchAPIKeys[provider] = newValue
                invalidateTest(provider)
                if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    settings.setExternalSearchAPIKey(nil, for: provider)
                }
            }
        )
    }

    private func canToggleProviderOn(_ provider: ExternalSearchProviderID) -> Bool {
        let providerSettings = settings.externalSearchSettings(for: provider)
        if provider.supportsAnonymous, providerSettings.anonymousMode { return true }
        return providerSettings.hasVerifiedCredential
            && !apiKeyDraft(for: provider).isEmpty
            && settings.externalSearchAPIKey(for: provider) == apiKeyDraft(for: provider)
    }

    private func apiKeyDraft(for provider: ExternalSearchProviderID) -> String {
        (externalSearchAPIKeys[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 各 Provider 官方 API Key 管理入口。
    ///
    /// 这些 URL 来自对应服务的官方文档 / 控制台入口,集中维护是为了避免 UI 中散落
    /// 字符串,后续服务方改 dashboard 路径时只需要更新这一处。
    private func externalSearchAPIKeyURL(for provider: ExternalSearchProviderID) -> URL {
        switch provider {
        case .anySearch:
            return URL(string: "https://anysearch.com/console/api-keys")!
        case .tavily:
            return URL(string: "https://app.tavily.com")!
        case .exa:
            return URL(string: "https://dashboard.exa.ai/api-keys")!
        case .braveLLMContext:
            return URL(string: "https://api-dashboard.search.brave.com")!
        case .firecrawl:
            return URL(string: "https://www.firecrawl.dev/app/api-keys")!
        }
    }

    private func loadExternalSearchAPIKeys() {
        externalSearchAPIKeys = Dictionary(uniqueKeysWithValues: ExternalSearchProviderID.allCases.map { provider in
            (provider, settings.externalSearchAPIKey(for: provider) ?? "")
        })
    }

    /// 测试按钮是否可点：匿名（keyless）模式无需 key；认证模式要求已输入 key。
    private func canTestExternalSearchKey(_ provider: ExternalSearchProviderID) -> Bool {
        if externalSearchAPIKeyTestStates[provider] == .testing { return false }
        let providerSettings = settings.externalSearchSettings(for: provider)
        if provider.supportsAnonymous, providerSettings.anonymousMode {
            return true
        }
        return !apiKeyDraft(for: provider).isEmpty
    }

    /// 使用输入框中的未保存 Key 发起真实 credential test。探测成功后才持久化；
    /// 失败时不保存候选 Key，也不自动启用 Provider。
    private func testExternalSearchAPIKey(_ provider: ExternalSearchProviderID) {
        let candidate = apiKeyDraft(for: provider)
        let providerSettings = settings.externalSearchSettings(for: provider)
        let anonymous = provider.supportsAnonymous && providerSettings.anonymousMode
        // 匿名（keyless）模式允许空 key；认证模式要求 key。
        guard anonymous || !candidate.isEmpty else { return }

        externalSearchAPIKeyTestStates[provider] = .testing
        let revision = UUID()
        externalSearchTestRevisions[provider] = revision
        Task {
            let tester = ExternalSearchCredentialTester(settings: settings)
            let outcome = await tester.test(
                provider: provider, candidateKey: candidate, anonymous: anonymous,
                isCurrent: { externalSearchTestRevisions[provider] == revision }
            )
            guard externalSearchTestRevisions[provider] == revision else { return }
            switch outcome {
            case .superseded:
                externalSearchAPIKeyTestStates[provider] = .idle
            case .succeeded:
                providersRequiringVerification.remove(provider)
                externalSearchAPIKeys[provider] = candidate
                externalSearchAPIKeyTestStates[provider] = .succeeded
            case .saveFailed:
                externalSearchAPIKeyTestStates[provider] = .saveFailed
            case .failed(let failure):
                externalSearchAPIKeyTestStates[provider] = .failed(
                    failure.friendlyMessage,
                    failure.technicalDetails
                )
            }
        }
    }

    /// 在绑定写入时同步撤销请求资格，避免异步 onChange 晚于网络回调导致旧 Key 落盘。
    private func invalidateTest(_ provider: ExternalSearchProviderID) {
        externalSearchTestRevisions[provider] = UUID()
        externalSearchAPIKeyTestStates[provider] = .idle
        expandedExternalSearchTechnicalDetails.remove(provider)
    }

    /// 仅展示已有测试状态，不发起请求；详情仍留在操作栏上方独立折叠。
    private func externalSearchAPIKeySummary(_ provider: ExternalSearchProviderID) -> some View {
        Group {
            switch externalSearchAPIKeyTestStates[provider] ?? .idle {
            case .failed(let message, _):
                Label(message, systemImage: "xmark.circle.fill")
            case .saveFailed:
                Label("settings.externalSearch.apiKey.saveFailed", systemImage: "xmark.circle.fill")
            case .testing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("settings.services.summary.checking")
                }
            case .succeeded:
                Label("settings.externalSearch.layout.testSucceeded", systemImage: "checkmark.circle.fill")
            case .idle:
                EmptyView()
            }
        }
        .font(.caption)
        .foregroundStyle(feedbackColor(provider))
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func externalSearchAPIKeyTestFeedback(_ provider: ExternalSearchProviderID) -> some View {
        switch externalSearchAPIKeyTestStates[provider] ?? .idle {
        case .idle, .testing, .saveFailed, .succeeded:
            EmptyView()
        case .failed(_, let details):
            if let details {
                Divider()
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedExternalSearchTechnicalDetails.contains(provider) },
                        set: { expanded in
                            if expanded { expandedExternalSearchTechnicalDetails.insert(provider) }
                            else { expandedExternalSearchTechnicalDetails.remove(provider) }
                        }
                    )
                ) {
                    Text(verbatim: details)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("settings.externalSearch.apiKey.errorDetails")
                }
                .disclosureGroupStyle(SettingsDisclosureGroupStyle(
                    accessibilityLabel: Text("settings.externalSearch.apiKey.errorDetails")
                ))
                .font(.caption)
            }
        }
    }

    private func feedbackColor(_ provider: ExternalSearchProviderID) -> Color {
        switch externalSearchAPIKeyTestStates[provider] ?? .idle {
        case .succeeded: return .green
        case .failed, .saveFailed: return .red
        case .idle, .testing: return .secondary
        }
    }

    /// Provider 凭据测试只属于当前设置视图，不向业务层暴露瞬时 UI 状态。
    private enum APIKeyTestState: Equatable {
        case idle
        case testing
        case succeeded
        case saveFailed
        case failed(String, String?)
    }
}
