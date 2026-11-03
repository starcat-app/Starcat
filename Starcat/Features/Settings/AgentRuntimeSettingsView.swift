//
//  AgentRuntimeSettingsView.swift
//  Starcat
//
//  Direct 渠道外部 Agent Runtime 的统一设置入口。
//
//  两个 Runtime 各自整行折叠；配置指南集中在末尾，不叠加额外卡片。
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
            CodexRuntimeSettingsCard()
            DeepSeekRuntimeSettingsCard()
            AgentRuntimeGuideNotice(destination: documentationURL)
        }
    }

    /// 文档站按 URL 前缀区分语言；跟随 App locale，避免中文界面跳到英文指南。
    private var documentationURL: URL {
        locale.identifier.hasPrefix("zh")
            ? Self.chineseDocumentationURL
            : Self.englishDocumentationURL
    }
}
