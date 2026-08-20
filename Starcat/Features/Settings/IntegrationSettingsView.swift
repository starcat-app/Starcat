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
    private static let browserPluginAnchor = "settings.integrations.browserPlugin"
    private static let externalSearchAnchor = "settings.integrations.externalSearch"
    private static let codebaseMemoryAnchor = "settings.integrations.codebaseMemory"

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
    /// 编辑期只维护草稿，保存时才写入配置并启动服务，避免输入过程中反复重绑端口。
    @State private var pluginPortDraft = ""
    @State private var localAPIKeyStore = StarcatLocalAPIKeyStore.shared
    @State private var isLocalAPIKeyRevealed = false
    @State private var isHoveringCopyLocalAPIKey = false
    @State private var isHoveringCopyPluginEndpoint = false
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
                    .id(Self.browserPluginAnchor)
                alfredSection
                anySearchSection
                    .id(Self.externalSearchAnchor)
                Section {
                VStack(alignment: .leading, spacing: 5) {
                    Text("settings.integration.codeFlow.outputDir.subtitle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                RepositoryArchiveLimitNotice(
                    maximumArchiveMB: settings.aiRepoContextMaximumArchiveMB
                )

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
                    Text("settings.integration.codebaseMemory.subtitle")
                        .font(.caption)
                    .foregroundStyle(.secondary)
                }

                CodebaseMemoryExecutableSettingsView()

                RepositoryArchiveLimitNotice(
                    maximumArchiveMB: settings.aiRepoContextMaximumArchiveMB
                )

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
                .id(Self.codebaseMemoryAnchor)
            }
            .formStyle(.grouped)
            .task { storage.reload() }
            .task { codebaseMemoryStorage.reload() }
            .task { loadExternalSearchAPIKeys() }
            .task {
                if pluginPortDraft.isEmpty {
                    pluginPortDraft = String(pluginConfiguration.port)
                }
                if pluginConfiguration.isEnabled {
                    CompanionServiceBootstrapper.apply(configuration: pluginConfiguration)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .starcatJumpToSettingsTab)) { note in
                let anchor: String
                switch note.object as? String {
                case "integrations.localAPIKey":
                    anchor = Self.localAPIKeyAnchor
                case "integrations.browserPlugin":
                    anchor = Self.browserPluginAnchor
                case "integrations.externalSearch":
                    anchor = Self.externalSearchAnchor
                case "integrations.codebaseMemory":
                    anchor = Self.codebaseMemoryAnchor
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

            // 拆成 Section 直接子视图，让 Form 自动画行分隔线（别捆在一个 VStack 里）。
            pluginInfoRow(
                titleKey: "settings.integration.browserPlugin.status",
                value: pluginStatusText,
                valueColor: pluginStatusColor
            )
            BrowserPluginPortEditorRow(portDraft: $pluginPortDraft) {
                savePluginPortAndStart()
            }
            pluginEndpointRow
            localAPIKeyReferenceRow

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
        static let chrome = URL(string: "https://github.com/starcat-app/starcat-chrome-plugin")!
        static let safari = URL(string: "https://github.com/starcat-app/starcat-safari-plugin")!
    }

    private var alfredSection: some View {
        Section {
            Text("settings.integration.alfred.subtitle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label {
                Text(verbatim: "Starcat Pro · MCP Service · Starcat CLI")
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: "checklist")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("settings.mcp.title") {
                    NotificationCenter.default.post(
                        name: .starcatJumpToSettingsTab,
                        object: "mcp"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                // Workflow 公开仓库和首个可安装 Release 尚未就绪。保留入口位置但禁用，
                // 避免正式版本把用户带到 404；发布完成后再恢复为 Link。
                Button("settings.integration.alfred.install") {}
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(true)
            }
        } header: {
            SettingsSectionHeader(
                verbatim: "Alfred",
                systemImage: "command",
                style: .prominent
            )
        }
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
        case .failed(let failure):
            return failure.localizedDescription
        }
    }

    private var pluginStatusColor: Color {
        switch pluginConfiguration.serverStatus {
        case .running:
            return .green
        case .failed:
            return .red
        case .stopped, .starting:
            return .secondary
        }
    }

    private var pluginEndpoint: String {
        "http://127.0.0.1:\(pluginConfiguration.port)"
    }

    private var pluginEndpointRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("settings.integration.browserPlugin.endpoint")
                .font(.body)
                .foregroundStyle(.primary)
                .frame(width: 88, alignment: .leading)
            Text(verbatim: pluginEndpoint)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            CopyFeedbackButton(
                providesContent: { pluginEndpoint },
                tooltip: "settings.integration.browserPlugin.copyEndpoint"
            ) { didCopy in
                tokenActionIcon(
                    systemImage: didCopy ? "checkmark.circle.fill" : "doc.on.doc",
                    foregroundStyle: didCopy ? Color.green : Color.secondary,
                    isHovering: isHoveringCopyPluginEndpoint
                )
            }
            .onHover { isHoveringCopyPluginEndpoint = $0 }
        }
    }

    private func pluginInfoRow(
        titleKey: LocalizedStringKey,
        value: String,
        isMonospacedValue: Bool = false,
        valueColor: Color = .primary
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(titleKey)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(width: 88, alignment: .leading)
            Text(verbatim: value)
                .font(isMonospacedValue ? .system(.body, design: .monospaced) : .body)
                .foregroundStyle(valueColor)
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
        // Companion 每次请求都会读取共享 Key Store，无需为换 Key 重绑同一端口。
    }

    /// 保存动作同时表达“我希望服务运行”：写入端口、保持 Toggle 开启，并按需重启。
    private func savePluginPortAndStart() {
        let value: Int
        switch BrowserPluginPortEditorRow.validate(pluginPortDraft) {
        case .empty:
            value = Int(CompanionConfiguration.defaultPort)
            pluginPortDraft = String(value)
        case .ok:
            value = Int(pluginPortDraft) ?? Int(CompanionConfiguration.defaultPort)
        case .nonNumericAttempt, .belowMinimum, .aboveMaximum:
            return
        }

        let previousPort = pluginConfiguration.port
        guard pluginConfiguration.updateConfiguredPort(value) else { return }
        pluginConfiguration.isEnabled = true

        if previousPort == pluginConfiguration.port {
            // 运行中无需无意义重绑；失败/停止态则由 apply 在原端口重新尝试。
            CompanionServiceBootstrapper.apply(configuration: pluginConfiguration)
        } else {
            CompanionServiceBootstrapper.restart(configuration: pluginConfiguration)
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

    /// Provider 直接作为 Section 的 Form 行输出，复用系统行高、分隔线和字号适配。
    /// 不能再套一层 VStack，否则 Form 只会把整个 Provider 列表识别为单行，内部只能
    /// 依赖固定高度和手动画 Divider，首尾也会叠加不一致的行内边距。
    @ViewBuilder
    private var externalSearchProviderList: some View {
        ForEach(ExternalSearchProviderID.allCases) { provider in
            externalSearchProviderHeader(provider)

            if expandedExternalSearchProviders.contains(provider) {
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
                    }
                }

                // 测试是独立操作，按设置页规范右对齐；结果与错误留在同行左侧，
                // 用户无需在 API Key 输入行和下方反馈之间来回寻找状态。
                HStack(alignment: .center, spacing: 8) {
                    externalSearchAPIKeyTestFeedback(provider)
                    // EmptyView 不参与布局，必须用独立 Spacer 保证无反馈时按钮仍右对齐。
                    Spacer(minLength: 8)

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
                    .fixedSize()
                    .disabled(apiKeyDraft(for: provider).isEmpty || externalSearchAPIKeyTestStates[provider] == .testing)
                }
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

// MARK: - Browser Plugin Port Editor

/// 端口输入不静默钳制：保留可见错误并禁用保存，直到用户给出合法值。
private enum BrowserPluginPortValidation: Equatable {
    case empty
    case ok
    case nonNumericAttempt
    case belowMinimum
    case aboveMaximum

    var isCommittable: Bool {
        switch self {
        case .empty, .ok: return true
        case .nonNumericAttempt, .belowMinimum, .aboveMaximum: return false
        }
    }

    var errorHintKey: LocalizedStringKey? {
        switch self {
        case .empty, .ok: return nil
        case .nonNumericAttempt: return "settings.integration.browserPlugin.port.error.digitsOnly"
        case .belowMinimum: return "settings.integration.browserPlugin.port.error.tooLow"
        case .aboveMaximum: return "settings.integration.browserPlugin.port.error.tooHigh"
        }
    }
}

/// Browser Plugin 端口行沿用 MCP 的桌面设置交互：数字草稿、明确校验、显式保存启动。
private struct BrowserPluginPortEditorRow: View {
    @Binding var portDraft: String
    let onSaveAndStart: () -> Void

    @State private var validation: BrowserPluginPortValidation = .empty
    @FocusState private var isPortFieldFocused: Bool

    /// 65535 的固定宽度，避免 Form 在中英文切换或窗口缩放时把输入框挤到下一行。
    private static let fieldWidth: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("settings.integration.browserPlugin.port")

                Spacer()

                TextField("", text: $portDraft, prompt: Text(verbatim: "5051"))
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .frame(width: Self.fieldWidth - 20)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(
                                isPortFieldFocused
                                    ? Color.accentColor
                                    : Color(nsColor: .separatorColor).opacity(0.65),
                                lineWidth: isPortFieldFocused ? 2 : 1
                            )
                    }
                    .frame(width: Self.fieldWidth)
                    .focused($isPortFieldFocused)
                    .accessibilityLabel(Text("settings.integration.browserPlugin.port"))
                    .onChange(of: portDraft) { _, newValue in
                        let hadInvalidChars = newValue.contains { !$0.isNumber }
                        let filtered = String(newValue.filter(\.isNumber).prefix(5))
                        if filtered != newValue {
                            portDraft = filtered
                        }
                        validation = Self.validate(filtered, hadInvalidChars: hadInvalidChars)
                    }
                    .onSubmit {
                        if validation.isCommittable { onSaveAndStart() }
                    }

                Button("settings.integration.browserPlugin.port.saveAndStart", action: onSaveAndStart)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .focusEffectDisabled()
                    .disabled(!validation.isCommittable)
            }

            if let errorKey = validation.errorHintKey {
                Text(errorKey)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("settings.integration.browserPlugin.port.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            validation = Self.validate(portDraft)
        }
    }

    /// 只过滤非法字符；范围错误保留草稿并交给提示文案解释。
    static func validate(
        _ draft: String,
        hadInvalidChars: Bool = false
    ) -> BrowserPluginPortValidation {
        if hadInvalidChars { return .nonNumericAttempt }
        if draft.isEmpty { return .empty }
        guard let value = Int(draft) else { return .nonNumericAttempt }
        if value < CompanionConfiguration.allowedPortRange.lowerBound { return .belowMinimum }
        if value > CompanionConfiguration.allowedPortRange.upperBound { return .aboveMaximum }
        return .ok
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
