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
/// 折叠标题始终展示实际检测状态；路径、说明和重检操作收进展开内容，选择后仍立即复检。
struct CodexRuntimeSettingsCard: View {
    @AppStorage(ExternalAgentRuntimePreferences.codexExecutablePathKey)
    private var customExecutablePath = ""

    @State private var status: AgentRuntimeSettingsStatus = .idle
    @State private var resolvedRuntimeDirectoryPath = ""
    @State private var isExpanded = false
    @State private var isInstalling = false
    @State private var actualVersion = ""

    private let resolver: ExternalAgentExecutableResolver

    init(resolver: ExternalAgentExecutableResolver = ExternalAgentExecutableResolver()) {
        self.resolver = resolver
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            AgentRuntimePathRow(
                caption: "settings.integration.tools.runtime.directory",
                path: resolvedRuntimeDirectoryPath
            ) {
                AgentRuntimePathTrailingActions(
                    path: resolvedRuntimeDirectoryPath,
                    isDisabled: status.isChecking || isInstalling,
                    onChoose: chooseRuntimeDirectory
                ) {
                    ResetIconButton(help: Text("settings.integration.agentRuntime.restoreAutomatic")) {
                        customExecutablePath = ""
                        refresh()
                    }
                    .disabled(customExecutablePath.isEmpty || status.isChecking || isInstalling)
                }
            }

            if !actualVersion.isEmpty {
                Text(verbatim: actualVersion)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            RuntimeDownloadButton(runtime: .codex, isInstalling: $isInstalling) { installation in
                customExecutablePath = installation.directory.path
                refresh()
            }
            HStack(spacing: 8) {
                AgentRuntimeFailureLabel(status: status)
                Spacer()
                AgentRuntimeInfoButton(kind: .codex)
                Button("settings.integration.agentRuntime.detectAgain", action: refresh)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(status.isChecking || isInstalling)
            }
        } label: {
            HStack(spacing: 8) {
                Text(verbatim: "Codex App Server")
                Spacer(minLength: 8)
                AgentRuntimeStatusChip(status: status)
            }
        }
        .disclosureGroupStyle(SettingsDisclosureGroupStyle(accessibilityLabel: Text(verbatim: "Codex App Server")))
        .task { refresh() }
        .task(id: resolvedRuntimeDirectoryPath) {
            actualVersion = ""
            guard let installation = try? CodexRuntimeInstallationResolver(executableResolver: resolver)
                .resolve(configuredPath: customExecutablePath) else { return }
            actualVersion = (try? await RuntimeDownloadInstaller.run(installation.executableURL, ["--version"]))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
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
            status = .ready
        } catch {
            resolvedRuntimeDirectoryPath = customExecutablePath
            status = .failure(error)
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
