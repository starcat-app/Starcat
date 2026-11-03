//
//  GitHubNotificationIssueSummaryMarkdownView.swift
//  Starcat
//
//  Issue 总结的局部 Markdown 阅读区。观察仅止于此视图，玻璃面板和详情页不会
//  随正文快照重算；完整段落冻结，尚未闭合的尾部最多以 8Hz 重新解析。
//

import MarkdownUI
import SwiftUI

/// 滚动状态属于当前阅读区，生成会话则由 Store 持有，收起面板不会取消请求。
struct GitHubNotificationIssueSummaryMarkdownView: View {
    let session: GitHubNotificationIssueSummarySession

    @State private var tail = ScrollTailController()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if session.isGenerating {
                    if let snapshot = session.streamingPresentation {
                        ForEach(snapshot.stableMarkdownChunks.indices, id: \.self) { index in
                            IssueSummaryMarkdownChunk(markdown: snapshot.stableMarkdownChunks[index])
                                .equatable()
                        }
                        if !snapshot.liveTail.isEmpty {
                            IssueSummaryMarkdownChunk(markdown: snapshot.liveTail)
                        }
                    }
                } else {
                    // 终态只进行一次全文排版以恢复跨段 Markdown 语义和文字选择。
                    IssueSummaryMarkdownChunk(markdown: session.completedMarkdown)
                        .textSelection(.enabled)
                }
                // 永久 sentinel 与真实滚动相位共同判断跟随；正文 revision 不调用 scrollTo。
                Color.clear
                    .frame(height: 1)
                    .onScrollVisibilityChange(threshold: 0.5) { tail.updateBottomVisibility($0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 可变正文不能创建 SelectionOverlay；过去曾造成 AttributeGraph 反馈循环。
            .textSelection(.disabled)
        }
        .defaultScrollAnchor(session.isGenerating ? .bottom : .top, for: .initialOffset)
        // 完成态调整面板高度只改变阅读视口，不能再被 sizeChanges 的底部锚点拉走。
        .defaultScrollAnchor(session.isGenerating && tail.isFollowing ? .bottom : nil, for: .sizeChanges)
        // 正文在内容层内缩，给贴着 ScrollView 右缘的滚动指示条让出 gutter，
        // 指示条不再压住每行末尾的文字。
        .contentMargins(.trailing, 10, for: .scrollContent)
        .onScrollPhaseChange { _, phase in tail.updatePhase(phase) }
        .onChange(of: session.isGenerating) { _, isGenerating in
            if isGenerating { tail.resumeFollowing() }
        }
        .environment(\.openURL, OpenURLAction { url in
            // 模型产生的链接与项目其它 AI 正文保持同一 http/https 打开边界。
            guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
                return .discarded
            }
            return .systemAction
        })
    }
}

/// 冻结块通过 Equatable 跳过后续尾部刷新带来的重复解析；字号仍跟随系统界面倍率。
private struct IssueSummaryMarkdownChunk: View, Equatable {
    let markdown: String

    @Environment(\.starcatInterfaceScale) private var interfaceScale

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.markdown == rhs.markdown }

    var body: some View {
        Markdown(markdown)
            .markdownTheme(summaryTheme)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 小型阅读面板不采用 GitHub 默认的大标题或不透明正文底色，避免破坏玻璃层次。
    private var summaryTheme: Theme {
        Theme.gitHub
            .text {
                ForegroundColor(.primary)
                BackgroundColor(nil)
                FontSize(13 * interfaceScale.multiplier)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.15)) }
                    .markdownMargin(top: 8, bottom: 6)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.1)) }
                    .markdownMargin(top: 8, bottom: 6)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle { FontWeight(.semibold) }
                    .markdownMargin(top: 8, bottom: 6)
            }
            .heading6 { configuration in
                configuration.label
                    .markdownTextStyle { FontWeight(.semibold); ForegroundColor(.secondary) }
                    .markdownMargin(top: 6, bottom: 4)
            }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.2))
                    .markdownMargin(top: 0, bottom: 8)
            }
    }
}
