//
//  AgentRuntimeSettingsView.swift
//  Starcat
//
//  Direct 渠道外部 Agent Runtime 的统一设置入口。
//

import SwiftUI

/// 汇总 Codex App Server 与 DeepSeek Harness 的安装检测和路径配置。
struct AgentRuntimeSettingsView: View {
    private static let documentationURL = URL(
        string: "https://starcat.mintlify.site/agent-workspace/runtime-setup"
    )!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("settings.integration.agentRuntime.description")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            CodexRuntimeSettingsCard()
            DeepSeekRuntimeSettingsCard()

            HStack {
                Spacer()
                Link(
                    "settings.integration.agentRuntime.openGuide",
                    destination: Self.documentationURL
                )
                .font(.caption)
            }
        }
    }
}
