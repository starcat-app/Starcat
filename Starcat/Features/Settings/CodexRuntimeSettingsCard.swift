//
//  CodexRuntimeSettingsCard.swift
//  Starcat
//
//  Codex App Server 的本地检测与可执行文件路径配置。
//

import AppKit
import SwiftUI

/// 在设置页管理 Codex CLI 路径，但不接触 Codex 的登录凭据。
struct CodexRuntimeSettingsCard: View {
    @AppStorage(ExternalAgentRuntimePreferences.codexExecutablePathKey)
    private var customExecutablePath = ""

    @State private var status: AgentRuntimeSettingsStatus = .idle
    @State private var resolvedExecutablePath = ""

    private let resolver: ExternalAgentExecutableResolver

    init(resolver: ExternalAgentExecutableResolver = ExternalAgentExecutableResolver()) {
        self.resolver = resolver
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("settings.integration.agentRuntime.codex.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent("settings.integration.agentRuntime.executable") {
                    pathValue(resolvedExecutablePath)
                }

                statusView

                HStack(spacing: 8) {
                    Spacer()

                    Button("settings.integration.agentRuntime.detectAgain") {
                        refresh()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(status.isChecking)

                    Button("settings.integration.agentRuntime.chooseExecutable") {
                        chooseExecutable()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(status.isChecking)

                    Button("settings.integration.agentRuntime.restoreAutomatic") {
                        customExecutablePath = ""
                        refresh()
                    }
                    .disabled(customExecutablePath.isEmpty || status.isChecking)
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label {
                Text(verbatim: "Codex App Server")
            } icon: {
                Image(systemName: "terminal")
            }
        }
        .task { refresh() }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle, .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("settings.integration.agentRuntime.detecting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Label("settings.integration.agentRuntime.codex.executableAvailable", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func pathValue(_ path: String) -> some View {
        Text(verbatim: path.isEmpty ? String.l10n("settings.integration.agentRuntime.notConfigured") : path)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(path)
    }

    /// 检测只验证可执行文件，认证状态继续由 `codex login status` 负责。
    /// 这样 Starcat 不需要读取 `CODEX_HOME` 中的任何凭据文件。
    @MainActor
    private func refresh() {
        guard !status.isChecking else { return }
        status = .checking
        do {
            let executable = try resolver.resolve(
                executableName: "codex",
                explicitPath: customExecutablePath
            )
            resolvedExecutablePath = executable.path
            status = .ready
        } catch {
            resolvedExecutablePath = customExecutablePath
            status = .failed(error.localizedDescription)
        }
    }

    /// 用户选择后先保存绝对路径，再复用同一检测流程验证可执行权限。
    @MainActor
    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = String.l10n("settings.integration.agentRuntime.codex.openPanel.title")
        panel.prompt = String.l10n("settings.integration.agentRuntime.openPanel.prompt")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        customExecutablePath = url.path
        refresh()
    }
}
