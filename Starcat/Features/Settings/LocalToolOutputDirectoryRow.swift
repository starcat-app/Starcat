//
//  LocalToolOutputDirectoryRow.swift
//  Starcat
//
//  三种本地产物共用的保存目录行，具体迁移、授权和错误处理仍由调用方负责。
//

import SwiftUI

/// 路径可以截断，选择、Finder 和恢复默认操作保持固定尺寸。
struct LocalToolOutputDirectoryRow: View {
    let path: String
    let hasCustomDirectory: Bool
    let onChoose: () -> Void
    let onReveal: () -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("settings.integration.tools.directory")
            AgentRuntimePathRow(path: path) {
                Button("settings.integration.agentRuntime.openPanel.prompt", action: onChoose)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .fixedSize()
                RevealInFinderIconButton(help: Text("settings.integration.codeFlow.outputDir.revealHelp"), action: onReveal)
                    .fixedSize()
                ResetIconButton(help: Text("settings.integration.codeFlow.outputDir.resetHelp"), action: onReset)
                    .disabled(!hasCustomDirectory)
                    .fixedSize()
            }
        }
    }
}
