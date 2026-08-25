//
//  CodexRuntimeSettingsCard.swift
//  Starcat
//
//  Codex App Server 的本地检测与可执行文件路径配置。
//

import AppKit
import SwiftUI

/// 在设置页管理完整 Codex CLI 或独立 App Server 目录，但不接触 Codex 的登录凭据。
///
/// 视觉对齐 CodeFlow 输出目录行：去掉 GroupBox 和刷新按钮。选择文件后会立刻复检；
/// 路径行只保留短「选择」、重置、Finder；重置在「选择」前面，两个图标共用 15pt + 28pt。
struct CodexRuntimeSettingsCard: View {
    @AppStorage(ExternalAgentRuntimePreferences.codexExecutablePathKey)
    private var customExecutablePath = ""

    @State private var status: AgentRuntimeSettingsStatus = .idle
    @State private var resolvedRuntimeDirectoryPath = ""
    @State private var executableKind: CodexRuntimeProcessArguments.ExecutableKind?

    private let resolver: ExternalAgentExecutableResolver

    init(resolver: ExternalAgentExecutableResolver = ExternalAgentExecutableResolver()) {
        self.resolver = resolver
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(verbatim: "Codex App Server")
                    .font(.callout.weight(.semibold))
                AgentRuntimeInfoButton(kind: .codex)
                Spacer(minLength: 8)
                AgentRuntimeStatusChip(
                    status: status,
                    readyDetail: executableKind?.displayName
                )
            }

            AgentRuntimePathRow(path: resolvedRuntimeDirectoryPath) {
                AgentRuntimePathTrailingActions(
                    path: resolvedRuntimeDirectoryPath,
                    isDisabled: status.isChecking,
                    onChoose: chooseRuntimeDirectory
                ) {
                    ResetIconButton(help: Text("settings.integration.agentRuntime.restoreAutomatic")) {
                        customExecutablePath = ""
                        refresh()
                    }
                    .disabled(customExecutablePath.isEmpty || status.isChecking)
                }
            }

            if let message = status.failureMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .task { refresh() }
    }

    /// 检测目录布局与必要 Host，认证状态继续由 `codex login status` 负责。
    /// 这样 Starcat 不需要读取 `CODEX_HOME` 中的任何凭据文件。
    @MainActor
    private func refresh() {
        guard !status.isChecking else { return }
        status = .checking
        do {
            let installation = try CodexRuntimeInstallationResolver(executableResolver: resolver)
                .resolve(configuredPath: customExecutablePath)
            resolvedRuntimeDirectoryPath = installation.configurationDirectoryURL.path
            executableKind = installation.kind
            status = .ready
        } catch {
            resolvedRuntimeDirectoryPath = customExecutablePath
            executableKind = nil
            status = .failed(error.localizedDescription)
        }
    }

    /// 设置只保存目录；运行层会在目录或其 `bin/` 下解析完整 CLI / App Server。
    @MainActor
    private func chooseRuntimeDirectory() {
        let panel = NSOpenPanel()
        panel.title = String.l10n("settings.integration.agentRuntime.codex.directoryOpenPanel.title")
        panel.prompt = String.l10n("settings.integration.agentRuntime.openPanel.prompt")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        customExecutablePath = url.path
        refresh()
    }
}
