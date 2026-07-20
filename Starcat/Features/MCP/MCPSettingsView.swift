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

    /// 端口输入草稿：编辑期不钳制、不写盘，避免全选替换被 binding setter 打断。
    /// 点「重启」或离开字段时再 `commitPortDraft()`。
    @State private var portDraft = ""

    var body: some View {
        @Bindable var settings = settings
        @Bindable var mcpService = dependencies.mcpService

        return Form {
            Section {
                Toggle(isOn: Binding(
                    get: { settings.mcpServiceEnabled },
                    set: { enabled in
                        settings.mcpServiceEnabled = enabled
                        mcpService.refreshForCurrentSettings()
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.mcp.enabled.title")
                        Text("settings.mcp.enabled.help")
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
                        Text("settings.mcp.remote.title")
                        Text("settings.mcp.remote.help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle(isOn: $settings.mcpExposePrivateNotes) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.mcp.privateNotes.title")
                        Text("settings.mcp.privateNotes.help")
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
                    systemImage: "point.3.connected.trianglepath.dotted",
                    style: .prominent
                )
            }

            Section {
                Toggle(isOn: $settings.mcpAllowLocalWrites) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.mcp.localWrites.title")
                        Text("settings.mcp.localWrites.help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle(isOn: $settings.mcpAllowBatchWrites) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.mcp.batchWrites.title")
                        Text("settings.mcp.batchWrites.help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!settings.mcpAllowLocalWrites)

                Toggle(isOn: $settings.mcpAllowDestructiveWrites) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.mcp.destructiveWrites.title")
                        Text("settings.mcp.destructiveWrites.help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!settings.mcpAllowLocalWrites)
            } header: {
                SettingsSectionHeader(
                    "settings.mcp.section.writes",
                    systemImage: "pencil.and.list.clipboard",
                    style: .prominent
                )
            }

            Section {
                setupActionRow(
                    title: "settings.mcp.agentSetup.cli.manual.title",
                    help: "settings.mcp.agentSetup.cli.manual.help"
                ) {
                    setupCopyButton(
                        content: { mcpService.cliInstallCommand },
                        tooltip: "settings.mcp.agentSetup.cli.manual.copy"
                    )
                }

                setupActionRow(
                    title: "settings.mcp.agentSetup.cli.agent.title",
                    help: "settings.mcp.agentSetup.cli.agent.help"
                ) {
                    setupCopyButton(
                        content: { mcpService.cliAgentInstallPrompt },
                        tooltip: "settings.mcp.agentSetup.cli.agent.copy"
                    )
                }

                setupActionRow(
                    title: "settings.mcp.agentSetup.cli.verify.title",
                    help: "settings.mcp.agentSetup.cli.verify.help"
                ) {
                    setupCopyButton(
                        content: { mcpService.cliVerificationCommand },
                        tooltip: "settings.mcp.agentSetup.cli.verify.copy"
                    )
                }
            } header: {
                SettingsSectionHeader(
                    "settings.mcp.agentSetup.cli.title",
                    systemImage: "terminal",
                    style: .prominent
                )
            }

            Section {
                setupActionRow(
                    title: "settings.mcp.agentSetup.pair.manual.title",
                    help: "settings.mcp.agentSetup.pair.manual.help"
                ) {
                    pairingCopyButton(
                        providesContent: { try mcpService.createPairingCommand() },
                        tooltip: "settings.mcp.agentSetup.pair.manual.copy",
                        isEnabled: isRunning(mcpService.state)
                    )
                }

                setupActionRow(
                    title: "settings.mcp.agentSetup.pair.agent.title",
                    help: "settings.mcp.agentSetup.pair.agent.help"
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
                    systemImage: "link.badge.plus",
                    style: .prominent
                )
            } footer: {
                Text("settings.mcp.agentSetup.security.help")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                setupActionRow(
                    title: "settings.mcp.agentSetup.mcp.claude.title",
                    help: "settings.mcp.agentSetup.mcp.claude.help"
                ) {
                    setupCopyButton(
                        content: { mcpService.claudeMCPConfiguration },
                        tooltip: "settings.mcp.agentSetup.mcp.claude.copy"
                    )
                }

                setupActionRow(
                    title: "settings.mcp.agentSetup.mcp.codex.title",
                    help: "settings.mcp.agentSetup.mcp.codex.help"
                ) {
                    setupCopyButton(
                        content: { mcpService.codexMCPConfiguration },
                        tooltip: "settings.mcp.agentSetup.mcp.codex.copy"
                    )
                }

                setupActionRow(
                    title: "settings.mcp.agentSetup.mcp.agent.title",
                    help: "settings.mcp.agentSetup.mcp.agent.help"
                ) {
                    setupCopyButton(
                        content: { mcpService.mcpAgentSetupPrompt },
                        tooltip: "settings.mcp.agentSetup.mcp.agent.copy"
                    )
                }
            } header: {
                SettingsSectionHeader(
                    "settings.mcp.agentSetup.mcp.title",
                    systemImage: "server.rack",
                    style: .prominent
                )
            } footer: {
                Text("settings.mcp.agentSetup.mcp.configuration.help")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                setupActionRow(
                    title: "settings.mcp.agentSetup.skill.manual.title",
                    help: "settings.mcp.agentSetup.skill.manual.help"
                ) {
                    setupCopyButton(
                        content: { mcpService.skillManualInstall },
                        tooltip: "settings.mcp.agentSetup.skill.manual.copy"
                    )
                }

                setupActionRow(
                    title: "settings.mcp.agentSetup.skill.agent.title",
                    help: "settings.mcp.agentSetup.skill.agent.help"
                ) {
                    setupCopyButton(
                        content: { mcpService.skillAgentInstallPrompt },
                        tooltip: "settings.mcp.agentSetup.skill.agent.copy"
                    )
                }
            } header: {
                SettingsSectionHeader(
                    "settings.mcp.agentSetup.skill.title",
                    systemImage: "wand.and.stars",
                    style: .prominent
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
                        systemImage: "laptopcomputer.and.iphone",
                        style: .prominent
                    )
                }
            }

            Section {
                Text("settings.mcp.proOnly.help")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// 设置页动作保持“说明在左、独立按钮在右”的统一密度；复制状态与剪贴板写入由
    /// `CopyFeedbackButton` 负责，避免每一行各自维护反馈计时器。
    private func setupActionRow<Action: View>(
        title: LocalizedStringKey,
        help: LocalizedStringKey,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
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
        CopyFeedbackButton(providesContent: content, tooltip: tooltip, style: .bordered) { didCopy in
            setupCopyLabel(didCopy: didCopy, key: tooltip)
        }
        .controlSize(.regular)
    }

    /// 配对命令每次点击即时生成，不能先缓存到 View state。这样用户手工配对与
    /// Agent 配对永远拿到相互独立、五分钟有效的一次性 secret。
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
            tooltip: tooltip,
            style: .bordered
        ) { didCopy in
            setupCopyLabel(didCopy: didCopy, key: tooltip)
        }
        .controlSize(.regular)
        .disabled(!isEnabled)
    }

    @ViewBuilder
    private func setupCopyLabel(didCopy: Bool, key: LocalizedStringKey) -> some View {
        if didCopy {
            Label("common.copy.copied", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
        } else {
            Label(key, systemImage: "doc.on.doc")
                .foregroundStyle(.primary)
        }
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
                Text("settings.mcp.port")

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
                    .accessibilityLabel(Text("settings.mcp.port"))
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
                Text("settings.mcp.port.hint")
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
