//
//  RepoAISummaryMarkdownView.swift
//  Starcat
//
//  AI 摘要 Markdown 渲染组件。
//
//  模块职责：
//  - 用 MarkdownUI 渲染详情页 AI 摘要；
//  - 让流式响应的增量文本可以持续以 Markdown 形态刷新；
//  - 把 README 的 WebView 渲染路线和 AI 摘要的短 Markdown 渲染路线分开。
//
//  关键约束：
//  - AI 摘要是 Starcat 自己控制的短文本，不是完整 GitHub README。
//    README 仍走现有 WebView/GitHub HTML 方案，避免把 README 渲染回退成不完整的 Markdown 子集。
//  - MarkdownUI 是纯 SwiftUI 组件，适合嵌入当前详情页 ScrollView；这里不启用图片加载等复杂能力。
//

import MarkdownUI
import SwiftUI

/// 详情页 AI 摘要的 Markdown 展示视图。
struct RepoAISummaryMarkdownView: View {

    let markdown: String

    var body: some View {
        Markdown(markdown)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
