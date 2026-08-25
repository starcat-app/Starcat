//
//  AgentRuntimeSettingsView.swift
//  Starcat
//
//  Direct 渠道外部 Agent Runtime 的统一设置入口。
//
//  布局对齐集成 Tab 的 CodeFlow 段：Form 行直接铺说明 / 提示条 / 两个 Runtime 块，
//  不再用 GroupBox 套卡片。长说明和「打开指南」收进提示条，避免页脚再挂一条链接。
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
        // 不用 VStack 包整页：作为 Form Section 的子视图时，Group 会拆成多行，
        // 才能吃到 grouped Form 的原生行距，观感与下方 CodeFlow 段一致。
        Group {
            Text("settings.integration.agentRuntime.description")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            AgentRuntimeGuideNotice(destination: documentationURL)

            CodexRuntimeSettingsCard()
            DeepSeekRuntimeSettingsCard()
        }
    }

    /// 文档站按 URL 前缀区分语言；跟随 App locale，避免中文界面跳到英文指南。
    private var documentationURL: URL {
        locale.identifier.hasPrefix("zh")
            ? Self.chineseDocumentationURL
            : Self.englishDocumentationURL
    }
}
