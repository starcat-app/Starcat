//
//  IntegrationSettingsView.swift
//  Starcat
//
//  设置页 → 扩展与连接：分别承载浏览器扩展与代码、本地工具。
//  自建后端 URL/API Key 仍归「自定义服务」，避免不同配置目的混在同一页面。
//

import AppKit
import SwiftUI

/// 扩展与连接组的二级页面。拆页只调整信息架构，不改变任何配置的持久化位置。
enum IntegrationSettingsPage: Hashable {
    case browserExtensions
    case localTools
}

struct IntegrationSettingsTab: View {
    private static let repoContextAnchor = "settings.ai.repoContext"
    private static let agentRuntimeAnchor = "settings.integrations.agentRuntime"
    private static let localAPIKeyAnchor = "settings.integrations.localAPIKey"
    private static let browserPluginAnchor = "settings.integrations.browserPlugin"
    private static let codebaseMemoryAnchor = "settings.integrations.codebaseMemory"

    let page: IntegrationSettingsPage

    @Environment(\.starcatInterfaceScale) private var interfaceScale
    /// CodeFlow 生成物不进数据库，设置页直接观察文件系统扫描结果。
    @State private var storage = CodeFlowStorage.shared
    @State private var codebaseMemoryStorage = CodebaseMemoryStorage.shared
    @State private var actionError: String?
    @State private var pluginConfiguration = CompanionConfiguration.shared
    /// 编辑期只维护草稿，保存时才写入配置并启动服务，避免输入过程中反复重绑端口。
    @State private var pluginPortDraft = ""
    @State private var localAPIKeyStore = StarcatLocalAPIKeyStore.shared
    @State private var isLocalAPIKeyRevealed = false
    @State private var isHoveringCopyPluginEndpoint = false
    @State private var isPluginPortExpanded = false
    @State private var isConfirmingLocalAPIKeyRotation = false
    @State private var browserSetupGuide: BrowserExtensionSetupGuide.Browser?
    // HOM-68 v3 (2026-06-15)：CodeFlow"一键清除"按钮搬到 存储 Tab → 缓存用量。
    // 本 Tab 仅保留"精细化操作"（输出目录配置、单项目预览/打开/删除）。
    // → 与 RepoContextSettingsSection 的产物管理同款职责划分。
    //
    // HOM-203（2026-06-16）：与代码上下文同款改造，移除项目明细列表 +
    // per-project 预览/打开/删除按钮——大数据量下 ForEach 渲染会卡顿，且"全部
    // 清除"在存储 Tab 已有入口。汇总 4 项数据切到 `summary` 缓存。

    init(page: IntegrationSettingsPage = .browserExtensions) {
        self.page = page
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                if page == .browserExtensions {
                    SettingsPageIntroduction(
                        title: "settings.navigation.item.browserExtensions",
                        systemImage: BusinessIcon.Symbol.browserExtensions.rawValue,
                        description: "settings.integration.browser.introduction.description",
                        context: "settings.integration.browser.introduction.context"
                    )
                } else {
                    SettingsPageIntroduction(
                        title: "settings.navigation.item.codeAndLocalTools",
                        systemImage: BusinessIcon.Symbol.codeContext.rawValue,
                        description: "settings.integration.tools.configuration.description",
                        context: "settings.integration.tools.configuration.context"
                    )
                }

                if page == .localTools {
                    // 沿用原跳转身份，其他工具的 ZIP「调整」入口仍定位到共享限制。
                    RepositorySourceDownloadSettingsSection()
                        .id(Self.repoContextAnchor)
                    RepoContextSettingsSection()
                }

                if page == .localTools,
                   DistributionGate().isAvailable(.externalAgentRuntime) {
                    Section {
                        AgentRuntimeSettingsView()
                    } header: {
                        SettingsSectionHeader(
                            "settings.integration.agentRuntime.title",
                            systemImage: "point.3.connected.trianglepath.dotted"
                        )
                    }
                    .id(Self.agentRuntimeAnchor)
                }

                if page == .browserExtensions {
                    browserPluginSection
                        .id(Self.browserPluginAnchor)
                    localAPIKeySection
                        .id(Self.localAPIKeyAnchor)
                    browserInstallationSection
                }

                if page == .localTools {
                    codeFlowSection
                    codebaseMemorySection
                        .id(Self.codebaseMemoryAnchor)
                    HStack {
                        Spacer()
                        Button("settings.integration.tools.openStorage") {
                            AppDelegate.openSettingsWindow(target: "storage")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                }
            }
            .formStyle(.grouped)
            .task {
                guard page == .localTools else { return }
                storage.reload()
                codebaseMemoryStorage.reload()
            }
            .task {
                guard page == .browserExtensions else { return }
                if pluginPortDraft.isEmpty {
                    pluginPortDraft = String(pluginConfiguration.port)
                }
                if pluginConfiguration.isEnabled {
                    CompanionServiceBootstrapper.apply(configuration: pluginConfiguration)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .starcatJumpToAIRepoContextSection)) { _ in
                guard page == .localTools else { return }
                // 页面切换后等待 Form 完成布局，再定位迁入的配置分组。
                DispatchQueue.main.async {
                    proxy.scrollTo(Self.repoContextAnchor, anchor: .top)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .starcatJumpToSettingsTab)) { note in
                let anchor: String
                switch note.object as? String {
                case "integrations.agentRuntime" where page == .localTools:
                    anchor = Self.agentRuntimeAnchor
                case "integrations.localAPIKey" where page == .browserExtensions:
                    anchor = Self.localAPIKeyAnchor
                case "integrations.browserPlugin" where page == .browserExtensions:
                    anchor = Self.browserPluginAnchor
                case "integrations.codebaseMemory" where page == .localTools:
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
        .confirmationDialog(
            "settings.integration.browser.key.confirmTitle",
            isPresented: $isConfirmingLocalAPIKeyRotation,
            titleVisibility: .visible
        ) {
            Button("settings.integration.browser.key.confirmAction", role: .destructive) {
                rotateLocalAPIKey()
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("settings.integration.browser.key.confirmMessage")
        }
        .sheet(item: $browserSetupGuide) { browser in
            BrowserExtensionSetupGuide(browser: browser)
                .appLocaleEnvironment()
        }
    }

    /// 三个工具共享相同的路径和单行统计布局，实际存储与操作继续各自独立。
    private var codeFlowSection: some View {
        Section {
            LocalToolOutputDirectoryRow(
                path: storage.outputDirectoryDisplayPath,
                hasCustomDirectory: storage.hasCustomOutputDirectory,
                onChoose: chooseOutputDirectory,
                onReveal: revealOutputDirectory,
                onReset: resetOutputDirectory
            )
            LocalToolStorageSummary(
                projectCount: storage.projectCount,
                totalBytes: storage.totalBytes,
                generationCount: storage.totalGenerationCount,
                latestGeneratedAt: storage.latestGeneratedAt
            )
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
            SettingsSectionHeader(verbatim: "CodeFlow", systemImage: "point.3.connected.trianglepath.dotted")
        }
    }

    private var codebaseMemorySection: some View {
        Section {
            CodebaseMemoryExecutableSettingsView()
            LocalToolOutputDirectoryRow(
                path: codebaseMemoryStorage.outputDirectoryDisplayPath,
                hasCustomDirectory: codebaseMemoryStorage.hasCustomOutputDirectory,
                onChoose: chooseCodebaseMemoryOutputDirectory,
                onReveal: revealCodebaseMemoryOutputDirectory,
                onReset: resetCodebaseMemoryOutputDirectory
            )
            LocalToolStorageSummary(
                projectCount: codebaseMemoryStorage.projectCount,
                totalBytes: codebaseMemoryStorage.totalBytes,
                generationCount: codebaseMemoryStorage.totalGenerationCount,
                latestGeneratedAt: codebaseMemoryStorage.latestGeneratedAt
            )
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
            SettingsSectionHeader(verbatim: "CodebaseMemory", systemImage: "point.3.filled.connected.trianglepath.dotted")
        }
    }

    private var localAPIKeySection: some View {
        Section {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.integration.browser.key.shared")
                        .foregroundStyle(.primary)
                    Text("settings.integration.browser.key.help")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Text(verbatim: displayedLocalAPIKey)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)

                tokenActionButton(
                    systemImage: isLocalAPIKeyRevealed ? "eye.slash" : "eye",
                    titleKey: isLocalAPIKeyRevealed
                        ? "settings.integration.localAPIKey.hide"
                        : "settings.integration.localAPIKey.reveal",
                    isHovering: false
                ) {
                    isLocalAPIKeyRevealed.toggle()
                }
            }

            HStack(alignment: .center, spacing: 12) {
                Text("settings.integration.localAPIKey.authorization")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                CopyFeedbackButton(
                    providesContent: { localAPIKeyStore.apiKey },
                    tooltip: "settings.integration.localAPIKey.copy"
                ) { didCopy in
                    Label(
                        LocalizedStringKey(
                            didCopy ? "settings.integration.browserPlugin.tokenCopied" : "settings.integration.browser.copy"
                        ),
                        systemImage: didCopy ? "checkmark.circle.fill" : "doc.on.doc"
                    )
                    .labelStyle(.iconOnly)
                    .font(SettingsIconMetrics.standardGlyph)
                    .foregroundStyle(didCopy ? Color.green : Color.secondary)
                    .frame(width: SettingsIconMetrics.actionFrameSize, height: SettingsIconMetrics.actionFrameSize)
                }
                .fixedSize()
                Button("settings.integration.browser.key.regenerate") {
                    isConfirmingLocalAPIKeyRotation = true
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .fixedSize()
            }
        } header: {
            SettingsSectionHeader(
                "settings.integration.localAPIKey.title",
                systemImage: "key.horizontal"
            )
        }
    }

    private var browserPluginSection: some View {
        Section {
            Toggle(
                "settings.integration.browser.connection.enabled",
                isOn: Binding(
                    get: { pluginConfiguration.isEnabled },
                    set: { isEnabled in
                        pluginConfiguration.isEnabled = isEnabled
                        CompanionServiceBootstrapper.apply(configuration: pluginConfiguration)
                    }
                )
            )
            .toggleStyle(.switch)

            // 拆成 Section 直接子视图，让 Form 自动画行分隔线（别捆在一个 VStack 里）。
            pluginInfoRow(
                titleKey: "settings.integration.browserPlugin.status",
                value: pluginStatusText,
                valueColor: pluginStatusColor
            )
            pluginEndpointRow

            DisclosureGroup(isExpanded: $isPluginPortExpanded) {
                BrowserPluginPortEditorRow(portDraft: $pluginPortDraft) {
                    savePluginPortAndStart()
                }
            } label: {
                HStack {
                    Text("settings.integration.browser.connection.port")
                    Spacer(minLength: 12)
                    Text(verbatim: String(pluginConfiguration.port))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .disclosureGroupStyle(SettingsDisclosureGroupStyle(
                accessibilityLabel: Text("settings.integration.browser.connection.port")
            ))
        } header: {
            SettingsSectionHeader(
                "settings.integration.browser.connection.title",
                systemImage: "macwindow"
            )
        }
    }

    /// 安装指引只展示步骤并跳转公开仓库，不下载、安装或更改浏览器权限。
    private var browserInstallationSection: some View {
        Section {
            ForEach(BrowserExtensionSetupGuide.Browser.allCases) { browser in
                LabeledContent {
                    Button("settings.integration.browser.install.guide") {
                        browserSetupGuide = browser
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .fixedSize()
                } label: {
                    Label {
                        Text(browser.titleKey)
                    } icon: {
                        Image(browser.rawValue)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                            .accessibilityHidden(true)
                    }
                }
            }

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.integration.browser.install.mcp")
                        .foregroundStyle(.primary)
                    Text("settings.integration.browser.install.mcpHelp")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("settings.integration.browser.install.openMCP") {
                    NotificationCenter.default.post(name: .starcatJumpToSettingsTab, object: "mcp")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .fixedSize()
            }
        } header: {
            SettingsSectionHeader(
                "settings.integration.browser.install.title",
                systemImage: "powerplug"
            )
        }
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
            Text("settings.integration.browser.connection.endpoint")
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Text(verbatim: pluginEndpoint)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(Text(verbatim: pluginEndpoint))
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
        HStack(alignment: .center, spacing: 10) {
            Text(titleKey)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(verbatim: value)
                .font(isMonospacedValue ? .system(.body, design: .monospaced) : .body)
                .foregroundStyle(valueColor)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(Text(verbatim: value))
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
                Text("settings.integration.tools.directory.reauthorizeTitle")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
            Text("settings.integration.tools.directory.reauthorizeHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button {
                    chooseCodebaseMemoryOutputDirectory()
                } label: {
                    Text("settings.integration.tools.directory.reauthorizeAction")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
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

            HStack(alignment: .center, spacing: 12) {
                Text("settings.integration.browser.connection.portDraftHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("settings.integration.browserPlugin.port.saveAndStart", action: onSaveAndStart)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(!validation.isCommittable)
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

#Preview {
    IntegrationSettingsTab(page: .browserExtensions)
        .frame(width: 560, height: 500)
}
