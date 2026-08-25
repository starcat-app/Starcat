//
//  DeepSeekRuntimeSettingsCard.swift
//  Starcat
//
//  DeepSeek Harness carrier、Cordis 配置与 Starcat Provider 的就绪检查。
//

import AppKit
import SwiftUI

/// 管理 DeepSeek Harness 的两个外部文件路径，并复用正式 adapter 的校验规则。
///
/// 两个路径各占一行，避免 LabeledContent 把超长 Application Support 路径折成密密麻麻的两列。
/// 选择后会立刻复检；不再单独放刷新按钮。每行提供 Finder 入口，方便定位埋在 venv 里的 carrier。
struct DeepSeekRuntimeSettingsCard: View {
    @Environment(AppSettings.self) private var settings

    @AppStorage(ExternalAgentRuntimePreferences.deepSeekExecutablePathKey)
    private var executablePath = ""
    @AppStorage(ExternalAgentRuntimePreferences.deepSeekCordisConfigPathKey)
    private var cordisConfigPath = ""

    @State private var status: AgentRuntimeSettingsStatus = .idle
    @State private var resolvedExecutablePath = ""

    private let resolver: ExternalAgentExecutableResolver

    init(resolver: ExternalAgentExecutableResolver = ExternalAgentExecutableResolver()) {
        self.resolver = resolver
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(verbatim: "DeepSeek Harness")
                    .font(.callout.weight(.semibold))
                AgentRuntimeInfoButton(kind: .deepSeek)
                Spacer(minLength: 8)
                AgentRuntimeStatusChip(status: status)
            }

            AgentRuntimePathRow(
                caption: "settings.integration.agentRuntime.executable",
                path: displayedExecutablePath
            ) {
                AgentRuntimePathTrailingActions(
                    path: displayedExecutablePath,
                    isDisabled: status.isChecking,
                    onChoose: chooseExecutable
                )
            }

            AgentRuntimePathRow(
                caption: "settings.integration.agentRuntime.cordisConfig",
                path: cordisConfigPath
            ) {
                AgentRuntimePathTrailingActions(
                    path: cordisConfigPath,
                    isDisabled: status.isChecking,
                    onChoose: chooseCordisConfig
                )
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

    /// 解析成功用 resolver 给出的绝对路径；失败时仍展示用户刚选的路径，方便对照 Finder。
    private var displayedExecutablePath: String {
        resolvedExecutablePath.isEmpty ? executablePath : resolvedExecutablePath
    }

    /// 与正式 Run 共用 adapter 构造校验，确保 carrier 三件套、Cordis 安全边界和
    /// 已验证的 AI Provider 任一缺失时，设置页立即显示同一份真实错误。
    @MainActor
    private func refresh() {
        guard !status.isChecking else { return }
        status = .checking
        do {
            let executable = try resolver.resolve(
                executableName: "dsh-jsonrpc-agent-pkg-macos-arm64",
                explicitPath: executablePath
            )
            _ = try ExternalAgentRuntimePreferences.makeAdapter(
                backend: .deepSeekHarness,
                resolver: resolver,
                settings: settings
            )
            resolvedExecutablePath = executable.path
            status = .ready
        } catch {
            resolvedExecutablePath = executablePath
            status = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = String.l10n("settings.integration.agentRuntime.deepSeek.openPanel.title")
        panel.prompt = String.l10n("settings.integration.agentRuntime.openPanel.prompt")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        executablePath = url.path
        refresh()
    }

    @MainActor
    private func chooseCordisConfig() {
        let panel = NSOpenPanel()
        panel.title = String.l10n("settings.integration.agentRuntime.deepSeek.cordisOpenPanel.title")
        panel.prompt = String.l10n("settings.integration.agentRuntime.openPanel.prompt")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        cordisConfigPath = url.path
        refresh()
    }
}
