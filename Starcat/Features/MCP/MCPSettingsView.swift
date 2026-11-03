//
//  MCPSettingsView.swift
//  Starcat
//
//  MCP Service 设置页。
//
//  本页只负责展示与触发本机 service 生命周期；真实权限判断在 `EntitlementGate`，
//  HTTP 请求层也会逐次校验 Pro + Bearer token，避免 UI 状态成为安全边界。
//

import AppKit
import SwiftUI

struct MCPSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppDependencies.self) private var dependencies
    @Environment(EntitlementGate.self) private var entitlementGate
    @Environment(\.locale) private var locale

    /// 端口输入草稿：编辑期不钳制、不写盘，避免全选替换被 binding setter 打断。
    /// 点「重启」或离开字段时再 `commitPortDraft()`。
    @State private var portDraft = ""

    var body: some View {
        @Bindable var settings = settings
        @Bindable var mcpService = dependencies.mcpService

        return Form {
            SettingsPageIntroduction(
                title: "settings.mcp.title",
                systemImage: BusinessIcon.Symbol.mcp.rawValue,
                description: "settings.mcp.introduction.description",
                context: "settings.mcp.content.introduction.context"
            )

            Section {
                Toggle(isOn: Binding(
                    get: { settings.mcpServiceEnabled },
                    set: { enabled in
                        settings.mcpServiceEnabled = enabled
                        mcpService.refreshForCurrentSettings()
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.mcp.content.service.enabledTitle")
                        Text("settings.mcp.content.service.enabledHelp")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                MCPPortEditorRow(portDraft: $portDraft) {
                    commitPortDraft()
                    mcpService.restartForCurrentSettings()
                }

                Toggle(isOn: Binding(
                    get: { settings.mcpAllowRemoteConnections },
                    set: { enabled in
                        settings.mcpAllowRemoteConnections = enabled
                        mcpService.restartForCurrentSettings()
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.mcp.content.service.remoteTitle")
                        Text("settings.mcp.content.service.remoteHelp")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle(isOn: $settings.mcpExposePrivateNotes) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.mcp.content.service.notesTitle")
                        Text("settings.mcp.content.service.notesHelp")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                LabeledContent("settings.mcp.status") {
                    Text(statusText(for: mcpService.state))
                        .foregroundStyle(statusColor(for: mcpService.state))
                }
            } header: {
                SettingsSectionHeader(
                    "settings.mcp.section.service",
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
            }

            Section {
                Toggle(isOn: $settings.mcpAllowLocalWrites) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.mcp.content.permissions.localTitle")
                        Text("settings.mcp.content.permissions.localHelp")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle(isOn: $settings.mcpAllowGitHubStarWrites) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.mcp.content.permissions.starsTitle")
                        Text("settings.mcp.content.permissions.starsHelp")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle(isOn: $settings.mcpAllowBatchWrites) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.mcp.content.permissions.batchTitle")
                        Text("settings.mcp.content.permissions.batchHelp")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!settings.mcpAllowLocalWrites)

                Toggle(isOn: $settings.mcpAllowDestructiveWrites) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.mcp.content.permissions.destructiveTitle")
                        Text("settings.mcp.content.permissions.destructiveHelp")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!settings.mcpAllowLocalWrites)
            } header: {
                SettingsSectionHeader(
                    "settings.mcp.section.writes",
                    systemImage: "pencil.and.list.clipboard"
                )
            }

            Section {
                setupActionRow(
                    title: "settings.mcp.content.quick.title",
                    help: "settings.mcp.content.quick.help"
                ) {
                    pairingCopyButton(
                        providesContent: { try mcpService.createCompleteAgentSetupInstruction() },
                        tooltip: "settings.mcp.agentSetup.complete.copy",
                        isEnabled: isRunning(mcpService.state)
                    )
                }
            } header: {
                SettingsSectionHeader(
                    "settings.mcp.agentSetup.complete.sectionTitle",
                    systemImage: "checklist"
                )
            } footer: {
                Text("settings.mcp.content.quick.footer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                setupActionRow(
                    title: "settings.mcp.content.setup.terminalTitle",
                    help: "settings.mcp.content.cli.manualHelp"
                ) {
                    setupCopyButton(
                        content: { mcpService.cliInstallCommand },
                        tooltip: "settings.mcp.agentSetup.cli.manual.copy"
                    )
                }

                setupActionRow(
                    title: "settings.mcp.agentSetup.execution.context.agent",
                    help: "settings.mcp.content.cli.agentHelp"
                ) {
                    setupCopyButton(
                        content: { mcpService.cliAgentInstallPrompt },
                        tooltip: "settings.mcp.agentSetup.cli.agent.copy"
                    )
                }

                setupActionRow(
                    title: "settings.mcp.content.cli.verifyTitle",
                    help: "settings.mcp.content.cli.verifyHelp"
                ) {
                    setupCopyButton(
                        content: { mcpService.cliVerificationCommand },
                        tooltip: "settings.mcp.agentSetup.cli.verify.copy"
                    )
                }
            } header: {
                SettingsSectionHeader(
                    "settings.mcp.agentSetup.cli.title",
                    systemImage: "terminal"
                )
            }

            Section {
                setupActionRow(
                    title: "settings.mcp.content.setup.terminalTitle",
                    help: "settings.mcp.content.pair.manualHelp"
                ) {
                    pairingCopyButton(
                        providesContent: { try mcpService.createPairingCommand() },
                        tooltip: "settings.mcp.agentSetup.pair.manual.copy",
                        isEnabled: isRunning(mcpService.state)
                    )
                }

                setupActionRow(
                    title: "settings.mcp.agentSetup.execution.context.agent",
                    help: "settings.mcp.content.pair.agentHelp"
                ) {
                    pairingCopyButton(
                        providesContent: { try mcpService.createPairingAgentInstruction() },
                        tooltip: "settings.mcp.agentSetup.pair.agent.copy",
                        isEnabled: isRunning(mcpService.state)
                    )
                }
            } header: {
                SettingsSectionHeader(
                    "settings.mcp.agentSetup.pair.title",
                    systemImage: "link.badge.plus"
                )
            } footer: {
                Text("settings.mcp.content.pair.footer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                setupActionRow(
                    title: "settings.mcp.agentSetup.mcp.claude.title",
                    help: "settings.mcp.content.client.claudeHelp"
                ) {
                    setupCopyButton(
                        content: { mcpService.claudeMCPConfiguration },
                        tooltip: "settings.mcp.agentSetup.mcp.claude.copy"
                    )
                }

                setupActionRow(
                    title: "settings.mcp.agentSetup.mcp.codex.title",
                    help: "settings.mcp.content.client.codexHelp"
                ) {
                    setupCopyButton(
                        content: { mcpService.codexMCPConfiguration },
                        tooltip: "settings.mcp.agentSetup.mcp.codex.copy"
                    )
                }

                setupActionRow(
                    title: "settings.mcp.agentSetup.execution.context.agent",
                    help: "settings.mcp.content.client.agentHelp"
                ) {
                    setupCopyButton(
                        content: { mcpService.mcpAgentSetupPrompt },
                        tooltip: "settings.mcp.agentSetup.mcp.agent.copy"
                    )
                }
            } header: {
                SettingsSectionHeader(
                    "settings.mcp.content.client.title",
                    systemImage: "server.rack"
                )
            } footer: {
                Text("settings.mcp.content.client.footer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                setupActionRow(
                    title: "settings.mcp.content.skill.manualTitle",
                    help: "settings.mcp.content.skill.manualHelp"
                ) {
                    setupCopyButton(
                        content: { mcpService.skillManualInstall },
                        tooltip: "settings.mcp.agentSetup.skill.manual.copy"
                    )
                }

                setupActionRow(
                    title: "settings.mcp.agentSetup.execution.context.agent",
                    help: "settings.mcp.content.skill.agentHelp"
                ) {
                    setupCopyButton(
                        content: { mcpService.skillAgentInstallPrompt },
                        tooltip: "settings.mcp.agentSetup.skill.agent.copy"
                    )
                }
            } header: {
                SettingsSectionHeader(
                    "settings.mcp.agentSetup.skill.title",
                    systemImage: "wand.and.stars"
                )
            }

            if !dependencies.mcpDeviceStore.devices.isEmpty {
                Section {
                    ForEach(dependencies.mcpDeviceStore.devices) { device in
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text("\(device.platform) / \(device.architecture) · \(device.cliVersion)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(pairedAtText(for: device))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 16)
                            Button("settings.mcp.devices.revoke", role: .destructive) {
                                try? dependencies.mcpDeviceStore.revoke(deviceID: device.id)
                            }
                            .buttonStyle(.bordered)
                            .focusEffectDisabled()
                        }
                    }
                } header: {
                    SettingsSectionHeader(
                        "settings.mcp.section.devices",
                        systemImage: "laptopcomputer.and.iphone"
                    )
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if portDraft.isEmpty {
                portDraft = String(settings.mcpServicePort)
            }
            mcpService.refreshForCurrentSettings()
        }
        .onChange(of: entitlementGate.isProUser) { _, _ in
            mcpService.refreshForCurrentSettings()
        }
    }

    /// 把草稿写入 `mcpServicePort`：空串 → 5555；合法数字 → 原样；非法时不应被调用（重启按钮已禁用）。
    private func commitPortDraft() {
        switch MCPPortEditorRow.validate(portDraft) {
        case .empty:
            settings.mcpServicePort = AppSettings.defaultMCPServicePort
            portDraft = String(AppSettings.defaultMCPServicePort)
        case .ok:
            settings.mcpServicePort = Int(portDraft) ?? AppSettings.defaultMCPServicePort
        case .nonNumericAttempt, .belowMinimum, .aboveMaximum:
            return
        }
    }

    private func statusText(for state: StarcatMCPService.State) -> String {
        switch state {
        case .stopped:
            return String.l10n("settings.mcp.status.stopped")
        case .running:
            return String.l10n("settings.mcp.status.running")
        case .failed(let message):
            return message
        }
    }

    private func statusColor(for state: StarcatMCPService.State) -> Color {
        switch state {
        case .running:
            return .green
        case .failed:
            return .red
        case .stopped:
            return .secondary
        }
    }

    private func isRunning(_ state: StarcatMCPService.State) -> Bool {
        if case .running = state { return true }
        return false
    }

    /// 使用绝对日期时间帮助用户稳定区分新旧配对；配对较早不等于凭据已失效，
    /// 因此这里只展示事实时间，不派生容易误导的 stale 状态。
    private func pairedAtText(for device: StarcatMCPPairedDevice) -> String {
        let timestamp = device.pairedAt.formatted(
            .dateTime
                .year()
                .month(.abbreviated)
                .day()
                .hour()
                .minute()
                .locale(locale)
        )
        return String(
            format: String.l10n("settings.mcp.devices.pairedAtFormat"),
            timestamp
        )
    }

    /// 设置页动作保持“说明在左、独立按钮在右”的统一密度；复制状态与剪贴板写入由
    /// `CopyFeedbackButton` 负责，避免每一行各自维护反馈计时器。
    private func setupActionRow<Action: View>(
        title: LocalizedStringKey,
        help: LocalizedStringKey,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                // 分组已说明操作目的，行标题只区分执行方式，避免重复安装或配置名称。
                Text(title)
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            action()
        }
    }

    private func setupCopyButton(
        content: @escaping () -> String,
        tooltip: LocalizedStringKey
    ) -> some View {
        CopyFeedbackButton(providesContent: content, tooltip: tooltip) { didCopy in
            setupCopyLabel(didCopy: didCopy, key: tooltip)
        }
    }

    /// 携带 invitation 的内容每次点击即时生成，不能先缓存到 View state。这样手工配对、
    /// Agent 配对与完整配置永远拿到相互独立、五分钟有效的一次性 secret。
    private func pairingCopyButton(
        providesContent: @escaping () throws -> String,
        tooltip: LocalizedStringKey,
        isEnabled: Bool
    ) -> some View {
        CopyFeedbackButton(
            performCopy: {
                guard let content = try? providesContent() else { return false }
                NSPasteboard.general.clearContents()
                return NSPasteboard.general.setString(content, forType: .string)
            },
            tooltip: tooltip
        ) { didCopy in
            setupCopyLabel(didCopy: didCopy, key: tooltip)
        }
        .disabled(!isEnabled)
    }

    private func setupCopyLabel(didCopy: Bool, key: LocalizedStringKey) -> some View {
        let accessibilityKey: LocalizedStringKey = didCopy ? "common.copy.copied" : key

        return Label(
            accessibilityKey,
            systemImage: didCopy ? "checkmark.circle.fill" : "doc.on.doc"
        )
        .labelStyle(.iconOnly)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(didCopy ? Color.green : Color.secondary)
        // 设置页 icon-only 操作统一使用 28pt 命中区；详细语义仍由 tooltip 与
        // accessibility label 承担，视觉上只保留可扫描的复制 / 成功图标。
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .accessibilityLabel(Text(accessibilityKey))
    }
}

// MARK: - MCP Port Editor

/// 端口草稿校验结果。非法时不静默改值，只展示提示并禁用「重启」。
private enum MCPPortValidation: Equatable {
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
        case .nonNumericAttempt: return "settings.mcp.port.error.digitsOnly"
        case .belowMinimum: return "settings.mcp.port.error.tooLow"
        case .aboveMaximum: return "settings.mcp.port.error.tooHigh"
        }
    }
}

/// MCP 端口行：标签、输入框、重启按钮在同一行，下方固定说明 / 错误提示。
///
/// 不用 `LabeledContent` / Form 双列布局 —— macOS 会把 placeholder 或 Int 值
/// 额外渲染一列，出现孤零零的 `5555` 和换行输入框（dong4j 2026-06-20 反馈）。
private struct MCPPortEditorRow: View {
    @Binding var portDraft: String
    let onRestart: () -> Void

    @State private var validation: MCPPortValidation = .empty
    @FocusState private var isPortFieldFocused: Bool

    /// 5 位 monospaced 数字（65535）固定宽度，禁止 Form 把输入框挤换行。
    private static let fieldWidth: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("settings.mcp.content.service.portTitle")

                Spacer()

                TextField("", text: $portDraft, prompt: Text(verbatim: "5555"))
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
                    .accessibilityLabel(Text("settings.mcp.content.service.portTitle"))
                    .onChange(of: portDraft) { _, newValue in
                        let hadInvalidChars = newValue.contains { !$0.isNumber }
                        let filtered = String(newValue.filter(\.isNumber).prefix(5))
                        if filtered != newValue {
                            portDraft = filtered
                        }
                        validation = Self.validate(filtered, hadInvalidChars: hadInvalidChars)
                    }
                    .onSubmit {
                        if validation.isCommittable { onRestart() }
                    }

                Button("settings.mcp.restart", action: onRestart)
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
                Text("settings.mcp.content.service.portHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            validation = Self.validate(portDraft)
        }
    }

    /// 只过滤非法字符；超出范围保留用户输入并返回对应校验态，由提示文案说明原因。
    static func validate(_ draft: String, hadInvalidChars: Bool = false) -> MCPPortValidation {
        if hadInvalidChars { return .nonNumericAttempt }
        if draft.isEmpty { return .empty }
        guard let value = Int(draft) else { return .nonNumericAttempt }
        if value < 1024 { return .belowMinimum }
        if value > 65_535 { return .aboveMaximum }
        return .ok
    }
}
