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
/// 折叠时仍展示实际状态；选择后立即复检，展开后也可重新检测外部程序和配置的变化。
struct DeepSeekRuntimeSettingsCard: View {
    @Environment(AppSettings.self) private var settings

    @AppStorage(ExternalAgentRuntimePreferences.deepSeekExecutablePathKey)
    private var executablePath = ""
    @AppStorage(ExternalAgentRuntimePreferences.deepSeekCordisConfigPathKey)
    private var cordisConfigPath = ""

    @State private var status: AgentRuntimeSettingsStatus = .idle
    @State private var resolvedExecutablePath = ""
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
                caption: "settings.integration.agentRuntime.executable",
                path: displayedExecutablePath
            ) {
                AgentRuntimePathTrailingActions(
                    path: displayedExecutablePath,
                    isDisabled: status.isChecking || isInstalling,
                    onChoose: chooseExecutable
                )
            }

            AgentRuntimePathRow(
                caption: "settings.integration.agentRuntime.cordisConfig",
                path: cordisConfigPath
            ) {
                AgentRuntimePathTrailingActions(
                    path: cordisConfigPath,
                    isDisabled: status.isChecking || isInstalling,
                    onChoose: chooseCordisConfig
                )
            }

            if !actualVersion.isEmpty {
                Text(verbatim: actualVersion)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            RuntimeDownloadButton(runtime: .deepSeek, isInstalling: $isInstalling) { installation in
                executablePath = installation.executable.path
                cordisConfigPath = installation.configuration?.path ?? ""
                refresh()
            }
            HStack(spacing: 8) {
                AgentRuntimeFailureLabel(status: status)
                Spacer()
                AgentRuntimeInfoButton(kind: .deepSeek)
                Button("settings.integration.agentRuntime.detectAgain", action: refresh)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(status.isChecking || isInstalling)
            }
        } label: {
            HStack(spacing: 8) {
                Text(verbatim: "DeepSeek Harness")
                Spacer(minLength: 8)
                AgentRuntimeStatusChip(status: status)
            }
        }
        .disclosureGroupStyle(SettingsDisclosureGroupStyle(accessibilityLabel: Text(verbatim: "DeepSeek Harness")))
        .task { refresh() }
        .task(id: executablePath) {
            actualVersion = ""
            guard !executablePath.isEmpty else { return }
            actualVersion = (try? await RuntimeDownloadInstaller.run(
                URL(fileURLWithPath: executablePath), ["--version"]
            ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
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
                executableName: DeepSeekHarnessRuntime.executableName,
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
            status = .failure(error)
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
