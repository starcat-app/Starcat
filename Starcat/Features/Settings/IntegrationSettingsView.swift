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
    @Environment(AppSettings.self) private var settings
    /// CodeFlow 生成物不进数据库，设置页直接观察文件系统扫描结果。
    @State private var storage = CodeFlowStorage.shared
    @State private var codebaseMemoryStorage = CodebaseMemoryStorage.shared
    @State private var actionError: String?
    @State private var anySearchAPIKey: String = ""
    @State private var showAnySearchAPIKey: Bool = false
    @State private var anySearchAPIKeyTestState: AnySearchAPIKeyTestState = .idle
    @State private var pluginConfiguration = CompanionConfiguration.shared
    @State private var isHoveringCopyToken = false
    @State private var isHoveringResetToken = false
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
        Form {
            browserPluginSection
            anySearchSection
            Section("CodeFlow") {
                VStack(alignment: .leading, spacing: 5) {
                    Label("settings.integration.codeFlow.outputDir.title", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.headline)
                    Text("settings.integration.codeFlow.outputDir.subtitle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text(storage.outputDirectoryDisplayPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(-1)
                    Spacer()
                    Button("settings.integration.codeFlow.outputDir.choose") { chooseOutputDirectory() }
                        .fixedSize()
                    Button {
                        revealOutputDirectory()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("settings.integration.codeFlow.outputDir.revealHelp")
                    .fixedSize()
                    Button {
                        resetOutputDirectory()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .disabled(!storage.hasCustomOutputDirectory)
                    .help("settings.integration.codeFlow.outputDir.resetHelp")
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
                        stat(titleKey: "settings.integration.codeFlow.stat.lastGenerated", value: date.formatted(date: .abbreviated, time: .shortened))
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
            }
            Section("CodebaseMemory") {
                VStack(alignment: .leading, spacing: 5) {
                    Label("3D Code Graph", systemImage: "point.3.filled.connected.trianglepath.dotted")
                        .font(.headline)
                    Text("Tree-sitter index + browser-based 3D visualization")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text(codebaseMemoryStorage.outputDirectoryDisplayPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(-1)
                    Spacer()
                    Button("settings.integration.codeFlow.outputDir.choose") { chooseCodebaseMemoryOutputDirectory() }
                        .fixedSize()
                    Button { revealCodebaseMemoryOutputDirectory() } label: {
                        Image(systemName: "folder")
                    }
                    .help("settings.integration.codeFlow.outputDir.revealHelp")
                    .fixedSize()
                    Button { resetCodebaseMemoryOutputDirectory() } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .disabled(!codebaseMemoryStorage.hasCustomOutputDirectory)
                    .help("settings.integration.codeFlow.outputDir.resetHelp")
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
                        stat(titleKey: "settings.integration.codeFlow.stat.lastGenerated", value: date.formatted(date: .abbreviated, time: .shortened))
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
            }
        }
        .formStyle(.grouped)
        .task { storage.reload() }
        .task { codebaseMemoryStorage.reload() }
        .task { anySearchAPIKey = settings.anySearchAPIKey() ?? "" }
        .task {
            if pluginConfiguration.isEnabled {
                CompanionServiceBootstrapper.apply(configuration: pluginConfiguration)
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

    private var browserPluginSection: some View {
        Section("settings.integration.browserPlugin.title") {
            VStack(alignment: .leading, spacing: 5) {
                Label("settings.integration.browserPlugin.header", systemImage: "puzzlepiece.extension")
                    .font(.headline)
                Text("settings.integration.browserPlugin.subtitle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                    value: "http://127.0.0.1:\(pluginConfiguration.port)/plugin/v1"
                )
                pluginTokenInfoRow
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
        let token = pluginConfiguration.token
        guard token.count > 12 else { return String(repeating: "•", count: max(token.count, 8)) }
        return "\(token.prefix(6))••••••\(token.suffix(6))"
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

    private func pluginInfoRow(titleKey: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(titleKey)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(verbatim: value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }

    private var pluginTokenInfoRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("settings.integration.browserPlugin.token")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(verbatim: maskedPluginToken)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            CopyFeedbackButton(
                providesContent: { pluginConfiguration.token },
                tooltip: "settings.integration.browserPlugin.copyToken"
            ) { didCopy in
                tokenActionIcon(
                    systemImage: didCopy ? "checkmark.circle.fill" : "doc.on.doc",
                    foregroundStyle: didCopy ? Color.green : Color.secondary,
                    isHovering: isHoveringCopyToken
                )
                .contentTransition(.symbolEffect(.replace))
            }
            .onHover { isHoveringCopyToken = $0 }
            tokenActionButton(
                systemImage: "arrow.clockwise",
                titleKey: "settings.integration.browserPlugin.resetToken",
                isHovering: isHoveringResetToken,
                action: resetPluginToken
            )
            .onHover { isHoveringResetToken = $0 }
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
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(foregroundStyle)
            .frame(width: 36, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(isHovering ? 0.14 : 0.10))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func copyPluginTokenToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pluginConfiguration.token, forType: .string)
    }

    private func resetPluginToken() {
        pluginConfiguration.resetToken()
        copyPluginTokenToPasteboard()
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
            }
        }
    }

    private var anySearchSection: some View {
        @Bindable var settings = settings
        return Section("settings.anySearch.title") {
            Toggle("settings.anySearch.enabled", isOn: $settings.anySearchEnabled)
            Toggle("settings.anySearch.anonymous", isOn: $settings.anySearchAnonymousMode)
                .disabled(!settings.anySearchEnabled)

            VStack(alignment: .leading, spacing: 8) {
                Text("settings.anySearch.apiKey")
                    .font(.callout.weight(.medium))

                HStack(spacing: 8) {
                    Group {
                        if showAnySearchAPIKey {
                            TextField("", text: $anySearchAPIKey, prompt: Text("settings.anySearch.apiKey.placeholder"))
                        } else {
                            SecureField("", text: $anySearchAPIKey, prompt: Text("settings.anySearch.apiKey.placeholder"))
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel(Text("settings.anySearch.apiKey"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .onChange(of: anySearchAPIKey) { _, _ in
                        anySearchAPIKeyTestState = .idle
                    }

                    Button {
                        showAnySearchAPIKey.toggle()
                    } label: {
                        Image(systemName: showAnySearchAPIKey ? "eye.slash" : "eye")
                            .frame(width: 18)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help(Text(showAnySearchAPIKey
                        ? LocalizedStringKey("settings.anySearch.apiKey.hide")
                        : LocalizedStringKey("settings.anySearch.apiKey.show")))

                    Button {
                        testAnySearchAPIKey()
                    } label: {
                        if anySearchAPIKeyTestState == .testing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("settings.anySearch.apiKey.test")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        anySearchAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            anySearchAPIKeyTestState == .testing
                    )
                }

                anySearchAPIKeyTestFeedback

                Text(settings.anySearchAnonymousMode
                    ? LocalizedStringKey("settings.anySearch.apiKey.anonymousDescription")
                    : LocalizedStringKey("settings.anySearch.apiKey.bearerDescription"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("settings.anySearch.includeWebInAll", isOn: $settings.searchIncludeWebInAll)
                .disabled(!settings.anySearchEnabled)
            Toggle("settings.anySearch.aiContext", isOn: $settings.aiExternalContextEnabled)
                .disabled(!settings.anySearchEnabled)
            Toggle("settings.anySearch.allowPrivateContext", isOn: $settings.aiExternalContextAllowPrivateRepos)
                .disabled(!settings.aiExternalContextEnabled)

            Text("settings.anySearch.privacyDescription")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 使用输入框中的未保存 Key 强制发起一次 Bearer 请求，避免匿名模式成功造成
    /// “Key 有效”的假阳性。探测成功后才持久化，失败时保留已有 Key 不变。
    private func testAnySearchAPIKey() {
        let candidate = anySearchAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }

        anySearchAPIKeyTestState = .testing
        Task {
            do {
                let client = AnySearchClient(apiKey: candidate, anonymous: false)
                _ = try await client.search(AnySearchRequest(query: "ping", maxResults: 1))
                settings.setAnySearchAPIKey(candidate)
                guard settings.anySearchAPIKey() == candidate else {
                    anySearchAPIKeyTestState = .saveFailed
                    return
                }
                anySearchAPIKey = candidate
                anySearchAPIKeyTestState = .succeeded
            } catch {
                anySearchAPIKeyTestState = .failed(error.localizedDescription)
            }
        }
    }

    @ViewBuilder
    private var anySearchAPIKeyTestFeedback: some View {
        switch anySearchAPIKeyTestState {
        case .idle, .testing:
            EmptyView()
        case .succeeded:
            Label("settings.anySearch.apiKey.testSucceeded", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .saveFailed:
            Label("settings.anySearch.apiKey.saveFailed", systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
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

private enum AnySearchAPIKeyTestState: Equatable {
    case idle
    case testing
    case succeeded
    case saveFailed
    case failed(String)
}

#Preview {
    IntegrationSettingsTab()
        .frame(width: 560, height: 500)
}
