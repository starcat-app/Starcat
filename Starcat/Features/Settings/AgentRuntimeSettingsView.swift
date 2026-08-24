//
//  AgentRuntimeSettingsView.swift
//  Starcat
//
//  Direct 渠道外部 Agent Runtime 的统一设置入口。
//

import SwiftUI

/// 汇总 Codex App Server 与 DeepSeek Harness 的安装检测和路径配置。
struct AgentRuntimeSettingsView: View {
    private static let englishDocumentationURL = URL(
        string: "https://starcat.mintlify.site/agent-workspace/runtime-setup"
    )!
    private static let chineseDocumentationURL = URL(
        string: "https://starcat.mintlify.site/zh-Hans/agent-workspace/runtime-setup"
    )!

    @Environment(\.locale) private var locale

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
                    destination: documentationURL
                )
                .font(.caption)
            }
        }
    }

    /// 文档站按 URL 前缀区分语言；跟随 App locale，避免中文界面跳到英文指南。
    private var documentationURL: URL {
        locale.identifier.hasPrefix("zh")
            ? Self.chineseDocumentationURL
            : Self.englishDocumentationURL
    }
}
