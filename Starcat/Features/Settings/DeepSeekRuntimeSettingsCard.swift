//
//  DeepSeekRuntimeSettingsCard.swift
//  Starcat
//
//  DeepSeek Harness carrier、Cordis 配置与 Starcat Provider 的就绪检查。
//

import AppKit
import SwiftUI

/// 管理 DeepSeek Harness 的两个外部文件路径，并复用正式 adapter 的校验规则。
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
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("settings.integration.agentRuntime.deepSeek.description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent("settings.integration.agentRuntime.executable") {
                    pathValue(resolvedExecutablePath.isEmpty ? executablePath : resolvedExecutablePath)
                }

                LabeledContent("settings.integration.agentRuntime.cordisConfig") {
                    pathValue(cordisConfigPath)
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

                    Button("settings.integration.agentRuntime.chooseCordisConfig") {
                        chooseCordisConfig()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(status.isChecking)
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label {
                Text(verbatim: "DeepSeek Harness")
            } icon: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
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
            Label("settings.integration.agentRuntime.deepSeek.configurationReady", systemImage: "checkmark.circle.fill")
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
