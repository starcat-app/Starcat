//
//  IntegrationSettingsView.swift
//  Starcat
//
//  设置页 → 集成 Tab：管理 CodeFlow 等直接嵌入 Starcat 的第三方工具。
//  自建后端 URL/API Key 仍归「服务」Tab，避免两类配置混在同一页面。
//

import AppKit
import SwiftUI

struct IntegrationSettingsTab: View {
    private static let localAPIKeyAnchor = "settings.integrations.localAPIKey"
    private static let externalSearchAnchor = "settings.integrations.externalSearch"

    @Environment(AppSettings.self) private var settings
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    /// Foundation date formatter 默认跟系统 locale；必须注入 App 语言，否则英文 UI 下仍可能显示「2026年7月10日」。
    @Environment(\.locale) private var locale
    /// CodeFlow 生成物不进数据库，设置页直接观察文件系统扫描结果。
    @State private var storage = CodeFlowStorage.shared
    @State private var codebaseMemoryStorage = CodebaseMemoryStorage.shared
    @State private var actionError: String?
    @State private var externalSearchAPIKeys: [ExternalSearchProviderID: String] = [:]
    @State private var visibleExternalSearchAPIKeys: Set<ExternalSearchProviderID> = []
    @State private var expandedExternalSearchProviders: Set<ExternalSearchProviderID> = []
    @State private var expandedExternalSearchTechnicalDetails: Set<ExternalSearchProviderID> = []
    @State private var externalSearchAPIKeyTestStates: [ExternalSearchProviderID: ExternalSearchAPIKeyTestState] = [:]
    @State private var pluginConfiguration = CompanionConfiguration.shared
    @State private var localAPIKeyStore = StarcatLocalAPIKeyStore.shared
    @State private var isLocalAPIKeyRevealed = false
    @State private var isHoveringCopyLocalAPIKey = false
    @State private var isHoveringRotateLocalAPIKey = false
    @State private var isHoveringChromePlugin = false
    @State private var isHoveringSafariPlugin = false
    // HOM-68 v3 (2026-06-15)：CodeFlow"一键清除"按钮搬到 存储 Tab → 缓存用量。
    // 本 Tab 仅保留"精细化操作"（输出目录配置、单项目预览/打开/删除）。
    // → 与 AISettingsView.repoContextManageStorageRow 同款职责划分。
    //
    // HOM-203（2026-06-16）：与 AISettingsView 同款改造，移除项目明细列表 +
    // per-project 预览/打开/删除按钮——大数据量下 ForEach 渲染会卡顿，且"全部
    // 清除"在存储 Tab 已有入口。汇总 4 项数据切到 `summary` 缓存。

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                localAPIKeySection
                    .id(Self.localAPIKeyAnchor)
                browserPluginSection
                anySearchSection
                    .id(Self.externalSearchAnchor)
                Section {
                VStack(alignment: .leading, spacing: 5) {
                    Text("settings.integration.codeFlow.outputDir.subtitle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text(storage.outputDirectoryDisplayPath)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(-1)
                    Spacer()
                    Button("settings.integration.codeFlow.outputDir.choose") { chooseOutputDirectory() }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .fixedSize()
                    Button {
                        revealOutputDirectory()
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("settings.integration.codeFlow.outputDir.revealHelp")
                    .accessibilityLabel(Text("settings.integration.codeFlow.outputDir.revealHelp"))
                    .fixedSize()
                    ResetIconButton(help: Text("settings.integration.codeFlow.outputDir.resetHelp")) {
                        resetOutputDirectory()
                    }
                    .disabled(!storage.hasCustomOutputDirectory)
                    .fixedSize()
                }

                HStack(spacing: 18) {
                    stat(titleKey: "settings.integration.codeFlow.stat.projects", value: "\(storage.projectCount)")
                    stat(titleKey: "settings.integration.codeFlow.stat.usage", value: ByteCountFormatter.string(fromByteCount: storage.totalBytes, countStyle: .file))
                    stat(
                        titleKey: "settings.integration.codeFlow.stat.totalGenerated",
                        value: String(format: String.l10n("settings.integration.codeFlow.stat.totalGeneratedFormat"), storage.totalGenerationCount)
                    )
                    if let date = storage.latestGeneratedAt {
                        stat(
                            titleKey: "settings.integration.codeFlow.stat.lastGenerated",
                            value: date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
                        )
                    }
                    Spacer()
                }

                if let message = storage.lastErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if storage.projectCount == 0 {
                    Text("settings.integration.codeFlow.empty")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                SettingsSectionHeader(
                    verbatim: "CodeFlow",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    style: .prominent
                )
            }
                Section {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Tree-sitter index + browser-based 3D visualization")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text(codebaseMemoryStorage.outputDirectoryDisplayPath)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(-1)
                    Spacer()
                    Button("settings.integration.codeFlow.outputDir.choose") { chooseCodebaseMemoryOutputDirectory() }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .fixedSize()
                    Button { revealCodebaseMemoryOutputDirectory() } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("settings.integration.codeFlow.outputDir.revealHelp")
                    .accessibilityLabel(Text("settings.integration.codeFlow.outputDir.revealHelp"))
                    .fixedSize()
                    ResetIconButton(help: Text("settings.integration.codeFlow.outputDir.resetHelp")) {
                        resetCodebaseMemoryOutputDirectory()
                    }
                    .disabled(!codebaseMemoryStorage.hasCustomOutputDirectory)
                    .fixedSize()
                }

                HStack(spacing: 18) {
                    stat(titleKey: "settings.integration.codeFlow.stat.projects", value: "\(codebaseMemoryStorage.projectCount)")
                    stat(titleKey: "settings.integration.codeFlow.stat.usage", value: ByteCountFormatter.string(fromByteCount: codebaseMemoryStorage.totalBytes, countStyle: .file))
                    stat(
                        titleKey: "settings.integration.codeFlow.stat.totalGenerated",
                        value: String(format: String.l10n("settings.integration.codeFlow.stat.totalGeneratedFormat"), codebaseMemoryStorage.totalGenerationCount)
                    )
                    if let date = codebaseMemoryStorage.latestGeneratedAt {
                        stat(
                            titleKey: "settings.integration.codeFlow.stat.lastGenerated",
                            value: date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
                        )
                    }
                    Spacer()
                }

                if codebaseMemoryStorage.needsDirectoryReauthorization {
                    codebaseMemoryReauthorizationPrompt
                } else if let message = codebaseMemoryStorage.lastErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if codebaseMemoryStorage.projectCount == 0 {
                    Text("settings.integration.codeFlow.empty")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                } header: {
                    SettingsSectionHeader(
                        verbatim: "CodebaseMemory",
                        systemImage: "point.3.filled.connected.trianglepath.dotted",
                        style: .prominent
                    )
                }
            }
            .formStyle(.grouped)
            .task { storage.reload() }
            .task { codebaseMemoryStorage.reload() }
            .task { loadExternalSearchAPIKeys() }
            .task {
                if pluginConfiguration.isEnabled {
                    CompanionServiceBootstrapper.apply(configuration: pluginConfiguration)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .starcatJumpToSettingsTab)) { note in
                let anchor: String
                switch note.object as? String {
                case "integrations.localAPIKey":
                    anchor = Self.localAPIKeyAnchor
                case "integrations.externalSearch":
                    anchor = Self.externalSearchAnchor
                default:
                    return
                }

                // SettingsView 会先切换 Tab；下一轮主队列再滚动，避免首次打开设置时目标 Section 尚未完成布局。
                DispatchQueue.main.async {
                    proxy.scrollTo(anchor, anchor: .top)
                }
            }
        }
        .alert("settings.integration.codeFlow.actionFailedTitle", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("common.ok") { actionError = nil }
        } message: {
            Text(actionError ?? String.l10n("common.unknownError"))
        }
    }

    private var localAPIKeySection: some View {
        Section {
            Text("settings.integration.localAPIKey.subtitle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center, spacing: 10) {
                Text("settings.integration.localAPIKey.value")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(width: 88, alignment: .leading)
                Text(verbatim: displayedLocalAPIKey)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                CopyFeedbackButton(
                    providesContent: { localAPIKeyStore.apiKey },
                    tooltip: "settings.integration.localAPIKey.copy"
                ) { didCopy in
                    tokenActionIcon(
                        systemImage: didCopy ? "checkmark.circle.fill" : "doc.on.doc",
                        foregroundStyle: didCopy ? Color.green : Color.secondary,
                        isHovering: isHoveringCopyLocalAPIKey
                    )
                    .contentTransition(.symbolEffect(.replace))
                }
                .onHover { isHoveringCopyLocalAPIKey = $0 }

                tokenActionButton(
                    systemImage: isLocalAPIKeyRevealed ? "eye.slash" : "eye",
                    titleKey: isLocalAPIKeyRevealed
                        ? "settings.integration.localAPIKey.hide"
                        : "settings.integration.localAPIKey.reveal",
                    isHovering: false
                ) {
                    isLocalAPIKeyRevealed.toggle()
                }

                tokenActionButton(
                    systemImage: "arrow.clockwise",
                    titleKey: "settings.integration.localAPIKey.rotate",
                    isHovering: isHoveringRotateLocalAPIKey
                ) {
                    rotateLocalAPIKey()
                }
                .onHover { isHoveringRotateLocalAPIKey = $0 }
            }

            Text("settings.integration.localAPIKey.authorization")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            SettingsSectionHeader(
                "settings.integration.localAPIKey.title",
                systemImage: "key.horizontal",
                style: .prominent
            )
        }
    }

    private var browserPluginSection: some View {
        Section {
            Text("settings.integration.browserPlugin.subtitle")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(
                "settings.integration.browserPlugin.enabled",
                isOn: Binding(
                    get: { pluginConfiguration.isEnabled },
                    set: { isEnabled in
                        pluginConfiguration.isEnabled = isEnabled
                        CompanionServiceBootstrapper.apply(configuration: pluginConfiguration)
                    }
                )
            )

            VStack(alignment: .leading, spacing: 8) {
                pluginInfoRow(
                    titleKey: "settings.integration.browserPlugin.status",
                    value: pluginStatusText
                )
                pluginInfoRow(
                    titleKey: "settings.integration.browserPlugin.endpoint",
                    value: "http://127.0.0.1:\(pluginConfiguration.port)/plugin/v1",
                    isMonospacedValue: true
                )
                localAPIKeyReferenceRow
            }

            LabeledContent {
                HStack(spacing: 10) {
                    browserPluginRepositoryLink(
                        assetName: "chrome",
                        titleKey: "settings.integration.browserPlugin.chromeRepository",
                        isHovering: isHoveringChromePlugin,
                        destination: BrowserPluginRepositoryLinks.chrome
                    )
                    .onHover { isHoveringChromePlugin = $0 }
                    browserPluginRepositoryLink(
                        assetName: "safari",
                        titleKey: "settings.integration.browserPlugin.safariRepository",
                        isHovering: isHoveringSafariPlugin,
                        destination: BrowserPluginRepositoryLinks.safari
                    )
                    .onHover { isHoveringSafariPlugin = $0 }
                }
            } label: {
                Text("settings.integration.browserPlugin.header")
            }

            Text("settings.integration.browserPlugin.description")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            SettingsSectionHeader(
                "settings.integration.browserPlugin.title",
                systemImage: "puzzlepiece.extension",
                style: .prominent
            )
        }
    }

    private enum BrowserPluginRepositoryLinks {
        // 两个插件源码独立开源，设置页跳公开仓库；不指向本机 supports 目录。
        static let chrome = URL(string: "https://github.com/dong4j/starcat-chrome-plugin")!
        static let safari = URL(string: "https://github.com/dong4j/starcat-safari-plugin")!
    }

    private func browserPluginRepositoryLink(
        assetName: String,
        titleKey: LocalizedStringKey,
        isHovering: Bool,
        destination: URL
    ) -> some View {
        Link(destination: destination) {
            browserPluginRepositoryIcon(assetName: assetName, isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(Text(titleKey))
        .accessibilityLabel(Text(titleKey))
    }

    private func browserPluginRepositoryIcon(assetName: String, isHovering: Bool) -> some View {
        Image(assetName)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 18, height: 18)
            .frame(width: 36, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(isHovering ? 0.14 : 0.10))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var maskedPluginToken: String {
        let token = localAPIKeyStore.apiKey
        guard token.count > 12 else { return String(repeating: "•", count: max(token.count, 8)) }
        return "\(token.prefix(6))••••••\(token.suffix(6))"
    }

    private var displayedLocalAPIKey: String {
        if isLocalAPIKeyRevealed { return localAPIKeyStore.apiKey }
        return maskedPluginToken
    }

    private var pluginStatusText: String {
        switch pluginConfiguration.serverStatus {
        case .stopped:
            return String.l10n("settings.integration.browserPlugin.status.stopped")
        case .starting:
            return String.l10n("settings.integration.browserPlugin.status.starting")
        case .running:
            return String.l10n("settings.integration.browserPlugin.status.running")
        case .failed:
            return String.l10n("settings.integration.browserPlugin.status.failed")
        }
    }

    private func pluginInfoRow(
        titleKey: LocalizedStringKey,
        value: String,
        isMonospacedValue: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(titleKey)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(width: 88, alignment: .leading)
            Text(verbatim: value)
                .font(isMonospacedValue ? .system(.body, design: .monospaced) : .body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }

    private var localAPIKeyReferenceRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("settings.integration.browserPlugin.apiKey")
                .font(.body)
                .foregroundStyle(.primary)
                .frame(width: 88, alignment: .leading)
            Text("settings.integration.browserPlugin.apiKey.description")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("settings.integration.localAPIKey.open") {
                NotificationCenter.default.post(
                    name: .starcatJumpToSettingsTab,
                    object: "integrations.localAPIKey"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .focusEffectDisabled()
        }
    }

    private func tokenActionButton(
        systemImage: String,
        titleKey: LocalizedStringKey,
        isHovering: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            tokenActionIcon(
                systemImage: systemImage,
                foregroundStyle: Color.secondary,
                isHovering: isHovering
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(Text(titleKey))
        .accessibilityLabel(Text(titleKey))
    }

    private func tokenActionIcon(
        systemImage: String,
        foregroundStyle: Color,
        isHovering: Bool
    ) -> some View {
        // 与全局设置页 icon-only 规范对齐：15pt glyph + 28pt 命中区，
        // 常态不铺底，只在 hover 时提供轻量背景反馈。
        Image(systemName: systemImage)
            .font(interfaceScale.font(.iconMedium, weight: .medium))
            .foregroundStyle(foregroundStyle)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(isHovering ? 0.14 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func rotateLocalAPIKey() {
        localAPIKeyStore.rotateAPIKey()
        if pluginConfiguration.isEnabled {
            CompanionServiceBootstrapper.apply(configuration: pluginConfiguration)
        }
    }

    private var codebaseMemoryReauthorizationPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(verbatim: "需要重新授权 CodebaseMemory 保存目录")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
            Text(verbatim: "当前目录授权已失效或无法访问。重新选择同一个目录即可恢复写入权限，已有索引数据不会被清除。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button {
                    chooseCodebaseMemoryOutputDirectory()
                } label: {
                    Text(verbatim: "重新授权目录")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
    }

    private var anySearchSection: some View {
        @Bindable var settings = settings
        return Group {
            Section {
                Toggle("settings.externalSearch.includeWebInAll", isOn: $settings.externalSearchIncludeInAll)
                Text("settings.externalSearch.includeWebInAll.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("settings.externalSearch.aiContext", isOn: $settings.externalContextEnabled)
                Text("settings.externalSearch.aiContext.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(isOn: aggregateExternalContextBinding) {
                    HStack(spacing: 6) {
                        Text("settings.externalSearch.aggregate")
                        if !settings.isProUser {
                            Text("Pro")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                        }
                    }
                }
                .disabled(!settings.isProUser)

                Toggle("settings.externalSearch.allowPrivateContext", isOn: $settings.externalSearchAllowPrivateRepos)
                    .disabled(!settings.externalContextEnabled)

                Picker("settings.externalSearch.defaultProvider", selection: $settings.externalSearchDefaultProvider) {
                    ForEach(ExternalSearchProviderID.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                Picker("settings.externalSearch.contextProvider", selection: $settings.externalContextProviderSelection) {
                    Text("settings.externalSearch.contextProvider.automatic").tag(ExternalContextProviderSelection.automatic)
                    ForEach(ExternalSearchProviderID.allCases) { provider in
                        Text(provider.displayName).tag(ExternalContextProviderSelection.provider(provider))
                    }
                }

                Text("settings.externalSearch.aggregate.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("settings.externalSearch.apiKey.testDescription")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                externalSearchProviderList
            } header: {
                SettingsSectionHeader(
                    "settings.externalSearch.section",
                    systemImage: "globe",
                    style: .prominent
                )
            }
        }
    }

    private var externalSearchProviderList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ExternalSearchProviderID.allCases.indices, id: \.self) { index in
                let provider = ExternalSearchProviderID.allCases[index]
                externalSearchProviderGroup(provider)
                if index < ExternalSearchProviderID.allCases.count - 1 {
                    Divider()
                }
            }
        }
    }

    private func externalSearchProviderGroup(_ provider: ExternalSearchProviderID) -> some View {
        let isExpanded = expandedExternalSearchProviders.contains(provider)
        return VStack(alignment: .leading, spacing: isExpanded ? 12 : 0) {
            externalSearchProviderHeader(provider)
                .frame(height: 54)

            if isExpanded {
                Toggle(isOn: providerEnabledBinding(provider)) {
                    Text("settings.externalSearch.provider.enable")
                }
                .disabled(!canToggleProviderOn(provider))

                if provider == .anySearch {
                    Toggle("settings.externalSearch.anonymous", isOn: providerAnonymousBinding(provider))
                        .disabled(!settings.externalSearchSettings(for: provider).isEnabled)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("settings.externalSearch.apiKey")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Link(
                            "settings.externalSearch.apiKey.get",
                            destination: externalSearchAPIKeyURL(for: provider)
                        )
                        .font(.caption.weight(.medium))
                    }

                    HStack(spacing: 8) {
                        Group {
                            if visibleExternalSearchAPIKeys.contains(provider) {
                                TextField("", text: apiKeyBinding(provider), prompt: Text(String(format: String.l10n("settings.externalSearch.apiKey.placeholderFormat"), provider.displayName)))
                            } else {
                                SecureField("", text: apiKeyBinding(provider), prompt: Text(String(format: String.l10n("settings.externalSearch.apiKey.placeholderFormat"), provider.displayName)))
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel(Text(String(format: String.l10n("settings.externalSearch.apiKey.accessibilityFormat"), provider.displayName)))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)

                        Button {
                            toggleAPIKeyVisibility(provider)
                        } label: {
                            Image(systemName: visibleExternalSearchAPIKeys.contains(provider) ? "eye.slash" : "eye")
                                .font(.system(size: 15, weight: .medium))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .help(visibleExternalSearchAPIKeys.contains(provider) ? "settings.externalSearch.apiKey.hide" : "settings.externalSearch.apiKey.show")
                        .accessibilityLabel(Text(visibleExternalSearchAPIKeys.contains(provider) ? "settings.externalSearch.apiKey.hide" : "settings.externalSearch.apiKey.show"))

                        Button {
                            testExternalSearchAPIKey(provider)
                        } label: {
                            if externalSearchAPIKeyTestStates[provider] == .testing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("settings.externalSearch.apiKey.test")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(apiKeyDraft(for: provider).isEmpty || externalSearchAPIKeyTestStates[provider] == .testing)
                    }

                    externalSearchAPIKeyTestFeedback(provider)
                }
                .padding(.bottom, 10)
            }
        }
    }

    private func externalSearchProviderHeader(_ provider: ExternalSearchProviderID) -> some View {
        let isExpanded = expandedExternalSearchProviders.contains(provider)
        return Button {
            toggleExternalSearchProviderExpansion(provider)
        } label: {
            HStack(spacing: 8) {
                Text(provider.displayName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private func toggleExternalSearchProviderExpansion(_ provider: ExternalSearchProviderID) {
        if expandedExternalSearchProviders.contains(provider) {
            expandedExternalSearchProviders.remove(provider)
        } else {
            expandedExternalSearchProviders.insert(provider)
        }
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
                guard !newValue || canToggleProviderOn(provider) else { return }
                providerSettings.isEnabled = newValue
                settings.setExternalSearchSettings(providerSettings, for: provider)
            }
        )
    }

    private func providerAnonymousBinding(_ provider: ExternalSearchProviderID) -> Binding<Bool> {
        Binding(
            get: { settings.externalSearchSettings(for: provider).anonymousMode },
            set: { newValue in
                var providerSettings = settings.externalSearchSettings(for: provider)
                providerSettings.anonymousMode = newValue
                settings.setExternalSearchSettings(providerSettings, for: provider)
            }
        )
    }

    private func apiKeyBinding(_ provider: ExternalSearchProviderID) -> Binding<String> {
        Binding(
            get: { externalSearchAPIKeys[provider] ?? "" },
            set: { newValue in
                externalSearchAPIKeys[provider] = newValue
                externalSearchAPIKeyTestStates[provider] = .idle
                if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    settings.setExternalSearchAPIKey(nil, for: provider)
                } else {
                    settings.clearExternalSearchCredentialVerification(for: provider)
                }
            }
        )
    }

    private func canToggleProviderOn(_ provider: ExternalSearchProviderID) -> Bool {
        let providerSettings = settings.externalSearchSettings(for: provider)
        if provider == .anySearch, providerSettings.anonymousMode { return true }
        return providerSettings.hasVerifiedCredential && settings.externalSearchAPIKey(for: provider)?.isEmpty == false
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
        }
    }

    private func toggleAPIKeyVisibility(_ provider: ExternalSearchProviderID) {
        if visibleExternalSearchAPIKeys.contains(provider) {
            visibleExternalSearchAPIKeys.remove(provider)
        } else {
            visibleExternalSearchAPIKeys.insert(provider)
        }
    }

    private func loadExternalSearchAPIKeys() {
        externalSearchAPIKeys = Dictionary(uniqueKeysWithValues: ExternalSearchProviderID.allCases.map { provider in
            (provider, settings.externalSearchAPIKey(for: provider) ?? "")
        })
    }

    /// 使用输入框中的未保存 Key 发起真实 credential test。探测成功后才持久化；
    /// 失败时不保存候选 Key，也不自动启用 Provider。
    private func testExternalSearchAPIKey(_ provider: ExternalSearchProviderID) {
        let candidate = apiKeyDraft(for: provider)
        guard !candidate.isEmpty else { return }

        externalSearchAPIKeyTestStates[provider] = .testing
        Task {
            let tester = ExternalSearchCredentialTester(settings: settings)
            switch await tester.test(provider: provider, candidateKey: candidate) {
            case .succeeded:
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

    @ViewBuilder
    private func externalSearchAPIKeyTestFeedback(_ provider: ExternalSearchProviderID) -> some View {
        switch externalSearchAPIKeyTestStates[provider] ?? .idle {
        case .idle, .testing:
            EmptyView()
        case .succeeded:
            Label("settings.externalSearch.apiKey.testSucceeded", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .saveFailed:
            Label("settings.externalSearch.apiKey.saveFailed", systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .failed(let message, let details):
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                if let details {
                    let isExpanded = expandedExternalSearchTechnicalDetails.contains(provider)
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { isExpanded },
                            set: { expanded in
                                if expanded { expandedExternalSearchTechnicalDetails.insert(provider) }
                                else { expandedExternalSearchTechnicalDetails.remove(provider) }
                            }
                        )
                    ) {
                        Text(details)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } label: {
                        Button {
                            if isExpanded { expandedExternalSearchTechnicalDetails.remove(provider) }
                            else { expandedExternalSearchTechnicalDetails.insert(provider) }
                        } label: {
                            HStack {
                                Text("settings.externalSearch.apiKey.technicalDetails")
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func stat(titleKey: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(titleKey).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium))
        }
    }

    // HOM-203：projectRow 已移除。per-project 详情 / 预览 / 打开 / 删除按钮全部
    // 砍掉，"全部清除"已在 设置 → 存储 Tab 提供。`storage.openPage` /
    // `revealPage` / `deleteProject` API 仍保留供后续视图（如未来的 CodeFlow
    // Tab）使用。

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = String.l10n("settings.integration.codeFlow.openPanel.title")
        panel.prompt = String.l10n("settings.integration.codeFlow.openPanel.prompt")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try storage.setCustomOutputDirectory(url)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func resetOutputDirectory() {
        do {
            try storage.resetOutputDirectory()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func revealOutputDirectory() {
        do {
            try storage.revealOutputRoot()
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: - CodebaseMemory 操作

    private func chooseCodebaseMemoryOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = String.l10n("settings.integration.codeFlow.openPanel.title")
        panel.prompt = String.l10n("settings.integration.codeFlow.openPanel.prompt")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try codebaseMemoryStorage.setCustomOutputDirectory(url)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func resetCodebaseMemoryOutputDirectory() {
        do {
            try codebaseMemoryStorage.resetOutputDirectory()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func revealCodebaseMemoryOutputDirectory() {
        do {
            try codebaseMemoryStorage.revealOutputRoot()
        } catch {
            actionError = error.localizedDescription
        }
    }

}

private enum ExternalSearchAPIKeyTestState: Equatable {
    case idle
    case testing
    case succeeded
    case saveFailed
    case failed(String, String?)
}

#Preview {
    IntegrationSettingsTab()
        .frame(width: 560, height: 500)
}
