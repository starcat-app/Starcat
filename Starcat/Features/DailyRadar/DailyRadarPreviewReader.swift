//
//  DailyRadarPreviewReader.swift
//  Starcat
//
//  沿用已验收的上滑阅读布局，正文、来源与原生项目卡片共用一个纵向滚动。
//  输入是固定 revision 的服务端内容，不再使用 Debug 示例。
//

import SwiftUI
import AppKit

/// 文章会话与首页刷新独立；关闭相关项目不会销毁文章的滚动位置。
struct DailyRadarPreviewReader: View {
    let story: DailyRadarReport
    let detail: DailyRadarReport?
    let availableWidth: CGFloat
    let failed: Bool
    let projectStore: DailyRadarProjectStore
    let retry: () -> Void
    let onClose: () -> Void
    let onProject: (DailyRadarReport.Project) -> Void
    @Environment(\.starcatInterfaceScale) private var scale
    @Environment(\.locale) private var locale
    @State private var markdownHeight: CGFloat = 100

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("dailyRadar.title", systemImage: "newspaper")
                    .font(scale.font(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(verbatim: languageLabel)
                    .font(scale.font(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                SheetCloseButton(action: onClose, helpKey: "dailyRadar.backToHome")
                    .accessibilityLabel(Text("dailyRadar.backToHome"))
            }
            .padding(.horizontal, 24)
            .frame(height: 52)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    GeometryReader { geometry in
                        DailyRadarCoverView(cover: story.cover, hero: true)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                    .frame(height: 310)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 28) {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 10) {
                                Text(verbatim: story.category)
                                Text("·")
                                Text(verbatim: DailyRadarDateFormatting.label(story.editionDate, locale: locale))
                            }
                            .font(scale.font(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            Text(verbatim: story.title.replacingOccurrences(of: "\n", with: ""))
                                .font(scale.font(size: 32, weight: .bold))
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)
                            Text(verbatim: story.summary)
                                .font(scale.font(size: 17))
                                .foregroundStyle(.secondary)
                                .lineSpacing(5)
                            HStack(spacing: 12) {
                                Label {
                                    Text(verbatim: String(format: String.l10n("dailyRadar.readingTime"), locale: locale, story.minutes.formatted(.number.locale(locale))))
                                } icon: { Image(systemName: "clock") }
                                Text(verbatim: languageLabel)
                            }
                            .font(scale.font(size: 11))
                            .foregroundStyle(.secondary)
                        }
                        Divider()
                        if let detail, let markdown = detail.markdown {
                            DailyRadarMarkdownView(markdown: markdown, identity: detail.contentIdentity, onLink: openLink, height: $markdownHeight)
                                .frame(height: markdownHeight)
                            if let source = detail.source {
                                VStack(alignment: .leading, spacing: 10) {
                                    Divider()
                                    Text("dailyRadar.source").font(scale.font(size: 12, weight: .semibold))
                                    if let safe = DailyRadarMarkdownRenderer.safeURL(source.url.absoluteString) {
                                        Link(destination: safe) {
                                            Label(source.name, systemImage: "arrow.up.right")
                                        }
                                        .help("dailyRadar.openSource")
                                    }
                                    Text("dailyRadar.generatedNotice")
                                        .font(scale.font(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let projects = detail.relatedProjects, !projects.isEmpty {
                                VStack(alignment: .leading, spacing: 16) {
                                    Text("dailyRadar.relatedProjects")
                                        .font(scale.font(size: 20, weight: .semibold))
                                        .accessibilityAddTraits(.isHeader)
                                    ForEach(projects) { project in
                                        DailyRadarRelatedProjectRow(project: project, store: projectStore) { onProject(project) }
                                    }
                                }
                            }
                        } else if failed {
                            ContentUnavailableView {
                                Label("error.loadFailed", systemImage: "exclamationmark.triangle")
                            } actions: {
                                Button("action.retry", action: retry)
                            }
                        } else {
                            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                        }
                    }
                    .frame(maxWidth: DailyRadarReaderLayout.contentMaxWidth(in: availableWidth), alignment: .leading)
                    .padding(.horizontal, DailyRadarReaderLayout.horizontalPadding)
                    .padding(.vertical, 36)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var languageLabel: String {
        String(format: String.l10n("dailyRadar.languageFormat"), locale: locale,
               locale.localizedString(forIdentifier: story.contentLanguage) ?? story.contentLanguage)
    }

    /// 仅已核验仓库首页接入项目面板；Issue/PR/Release 与新闻保持原链接含义。
    private func openLink(_ url: URL) {
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if url.host?.lowercased() == "github.com",
           path.split(separator: "/").count == 2,
           let project = detail?.relatedProjects?.first(where: { $0.id.lowercased() == path.lowercased() }) {
            onProject(project)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

/// 阅读区宽度策略独立出来，便于用测试锁定最小、自适应与超宽封顶行为。
enum DailyRadarReaderLayout {
    /// 小窗口下先比旧版 720pt 更宽，缓解日报表格拥挤；宽窗口按比例增长。
    static let minimumContentWidth: CGFloat = 760
    /// 与首页内容体系一致，超宽窗口不把正文行长无限拉长。
    static let maximumContentWidth: CGFloat = 1120
    static let horizontalPadding: CGFloat = 28

    /// 中右联合区域的可用宽度是唯一输入；不假设侧栏、中栏或窗口固定尺寸。
    static func contentMaxWidth(in availableWidth: CGFloat) -> CGFloat {
        guard availableWidth.isFinite, availableWidth > 0 else { return minimumContentWidth }
        let proportionalWidth = availableWidth * 0.84
        let availableContentWidth = max(0, availableWidth - horizontalPadding * 2)
        return min(
            maximumContentWidth,
            max(minimumContentWidth, proportionalWidth),
            availableContentWidth
        )
    }
}
