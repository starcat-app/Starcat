//
//  CodebaseMemoryExecutableSettingsView.swift
//  Starcat
//
//  设置页中的 CodebaseMemory 可执行文件状态与恢复操作。
//
//  Direct 允许选择用户已有的可执行文件，App Store 只展示 bundle 内资源状态。
//  NSOpenPanel 是 SwiftUI 没有直接替代的桌面能力，因此桥接仅限于选择文件这一处；
//  路径解析、持久化和版本探测仍全部由 CodebaseMemoryBinaryResolver 负责。
//

import AppKit
import SwiftUI

struct CodebaseMemoryExecutableSettingsView: View {
    private enum ResolutionState: Equatable {
        case idle
        case resolving
        case available(CodebaseMemoryExecutable)
        case unavailable(String)
    }

    @State private var resolutionState: ResolutionState = .idle
    @State private var hasUserSelection = false

    private let channel: DistributionChannel
    private let resolver: CodebaseMemoryBinaryResolver

    init(
        channel: DistributionChannel = .current,
        resolver: CodebaseMemoryBinaryResolver = CodebaseMemoryBinaryResolver()
    ) {
        self.channel = channel
        self.resolver = resolver
    }

    var body: some View {
        Group {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.integration.tools.program")
                    if case .available(let executable) = resolutionState {
                        Text(verbatim: executableDescription(executable))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                executableStatus
            }

            if case .unavailable(let message) = resolutionState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            // App Store 始终使用内置程序，不展示外部路径选择或自动检测恢复入口。
            if channel.isDirect {
                AgentRuntimePathRow(
                    caption: "settings.integration.agentRuntime.executable",
                    path: displayedExecutablePath
                ) {
                    AgentRuntimePathTrailingActions(
                        path: displayedExecutablePath,
                        isDisabled: isResolving,
                        onChoose: chooseExecutable
                    ) {
                        ResetIconButton(help: Text("settings.integration.codebaseMemory.executable.restoreAutomatic")) {
                            Task { await restoreAutomaticDetection() }
                        }
                        .disabled(!hasUserSelection || isResolving)
                    }
                }
            }

            HStack(spacing: 8) {
                Spacer()
                if channel.isDirect {
                    Link(
                        "settings.integration.codebaseMemory.executable.install",
                        destination: CodebaseMemoryBinaryResolver.installationURL
                    )
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
                Button("settings.integration.codebaseMemory.executable.detectAgain") {
                    Task { await refresh() }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(isResolving)
            }
        }
        .task { await refresh() }
    }

    /// 状态、版本和来源来自 resolver 的同一次结果，不把示例版本或路径带入设置页。
    @ViewBuilder
    private var executableStatus: some View {
        switch resolutionState {
        case .idle, .resolving:
            Text("settings.integration.codebaseMemory.executable.detecting")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .available:
            Label("settings.integration.agentRuntime.status.ready", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .unavailable:
            Label("settings.integration.tools.runtime.unavailable", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var displayedExecutablePath: String {
        if case .available(let executable) = resolutionState { return executable.url.path }
        return ""
    }

    private var isResolving: Bool {
        if case .resolving = resolutionState { return true }
        return false
    }

    private func executableDescription(_ executable: CodebaseMemoryExecutable) -> String {
        let sourceKey: String
        switch executable.source {
        case .bundled:
            sourceKey = "settings.integration.codebaseMemory.executable.source.bundled"
        case .automatic:
            sourceKey = "settings.integration.codebaseMemory.executable.source.automatic"
        case .userSelected:
            sourceKey = "settings.integration.codebaseMemory.executable.source.userSelected"
        }
        return "\(executable.version) · \(String.l10n(sourceKey))"
    }

    @MainActor
    private func refresh() async {
        guard !isResolving else { return }
        resolutionState = .resolving
        hasUserSelection = await resolver.hasUserSelectedExecutable()
        do {
            resolutionState = .available(try await resolver.resolveExecutableInfo())
        } catch {
            resolutionState = .unavailable(error.localizedDescription)
        }
    }

    /// 选择面板只负责返回 URL；Resolver 验证通过后才会保存路径。
    @MainActor
    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = String.l10n("settings.integration.codebaseMemory.executable.openPanel.title")
        panel.prompt = String.l10n("settings.integration.codebaseMemory.executable.openPanel.prompt")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        resolutionState = .resolving
        Task {
            do {
                resolutionState = .available(try await resolver.selectExecutable(url))
                hasUserSelection = true
            } catch {
                resolutionState = .unavailable(error.localizedDescription)
                hasUserSelection = await resolver.hasUserSelectedExecutable()
            }
        }
    }

    @MainActor
    private func restoreAutomaticDetection() async {
        await resolver.restoreAutomaticDetection()
        await refresh()
    }
}
