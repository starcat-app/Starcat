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
            Section("settings.mcp.section.service") {
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

                Toggle(isOn: $settings.mcpExposePrivateNotes) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.mcp.privateNotes.title")
                        Text("settings.mcp.privateNotes.help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section("settings.mcp.section.writes") {
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
            }

            Section("settings.mcp.section.connection") {
                LabeledContent("settings.mcp.status") {
                    Text(statusText(for: mcpService.state))
                        .foregroundStyle(statusColor(for: mcpService.state))
                }

                LabeledContent("settings.mcp.endpoint") {
                    Text(mcpService.endpointURL)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }

                SecureTokenRow(token: mcpService.bearerToken)

                HStack {
                    Spacer()

                    Button("settings.mcp.rotateToken") {
                        mcpService.rotateToken()
                    }
                    .focusEffectDisabled()

                    Button("settings.mcp.copyConfig") {
                        copy(mcpService.clientConfigSnippet)
                    }
                    .focusEffectDisabled()
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

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
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

private struct SecureTokenRow: View {
    let token: String
    @State private var isRevealed = false

    var body: some View {
        LabeledContent("settings.mcp.token") {
            HStack(spacing: 8) {
                Text(isRevealed ? token : String(repeating: "•", count: 24))
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Button(isRevealed ? "settings.mcp.token.hide" : "settings.mcp.token.reveal") {
                    isRevealed.toggle()
                }
                .focusEffectDisabled()
            }
        }
    }
}
