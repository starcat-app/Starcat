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
    /// 保持用户进入时的分类上下文，不因打开报告而回到固定的总览标题。
    let workspaceTitle: String
    let workspaceCategory: String?
    let availableWidth: CGFloat
    let failed: Bool
    let projectStore: DailyRadarProjectStore
    let retry: () -> Void
    let onClose: () -> Void
    let onProject: (DailyRadarReport.Project) -> Void
    @Environment(\.starcatInterfaceScale) private var scale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @State private var markdownHeight: CGFloat = 100
    @State private var markdownReady = false
    @State private var heroAppeared = false
    @State private var headerAppeared = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label {
                    Text(verbatim: workspaceTitle)
                } icon: {
                    DailyRadarCategoryIcon(categoryID: workspaceCategory, size: 13 * scale.multiplier)
                }
                    .font(scale.font(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                SheetCloseButton(action: onClose, helpKey: "dailyRadar.backToHome")
                    .accessibilityLabel(Text("dailyRadar.backToHome"))
            }
            .padding(.horizontal, 24)
            .frame(height: DailyRadarReaderLayout.headerHeight)
            // 阅读页也覆盖系统标题栏；只让标题空白背景承担窗口拖动。
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())
                    .allowsWindowActivationEvents()
            }
            Divider()
                .frame(height: DailyRadarReaderLayout.headerDividerHeight)
            ScrollView {
                VStack(spacing: 0) {
                    GeometryReader { geometry in
                        let scrolledDistance = max(0, -geometry.frame(
                            in: .named(DailyRadarReaderLayout.scrollCoordinateSpace)
                        ).minY)
                        let fadeProgress = min(1, scrolledDistance / DailyRadarReaderLayout.heroHeight)
                        ZStack {
                            DailyRadarCoverView(cover: story.cover, category: story.category,
                                                seed: story.id)
                                .scaleEffect(heroAppeared || reduceMotion ? 1 : 1.015)
                                // 图片滞后于滚动容器形成轻视差；只移动位图，不改变 hero 占位高度。
                                .offset(y: reduceMotion ? 0 : scrolledDistance * DailyRadarReaderLayout.heroParallaxFactor)
                                .opacity(reduceMotion ? 1 : 1 - fadeProgress * 0.65)
                        }
                        .opacity(heroAppeared || reduceMotion ? 1 : 0)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                    }
                    .frame(height: DailyRadarReaderLayout.heroHeight)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: heroAppeared)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 28) {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 10) {
                                Text(verbatim: DailyRadarCatalog.Category.localizedTitle(for: story.category))
                                Text("·")
                                Text(verbatim: DailyRadarDateFormatting.label(article?.editionDate ?? story.editionDate, locale: locale))
                            }
                            .font(scale.font(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .opacity(headerAppeared || reduceMotion ? 1 : 0)
                            .offset(y: headerAppeared || reduceMotion ? 0 : 12)
                            Text(verbatim: (article?.title ?? story.title).replacingOccurrences(of: "\n", with: ""))
                                .font(scale.font(size: 32, weight: .bold))
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)
                                .opacity(headerAppeared || reduceMotion ? 1 : 0)
                                .offset(y: headerAppeared || reduceMotion ? 0 : 12)
                            Group {
                                if let article {
                                    DailyRadarArticleSummary(summary: article.summary)
                                        .id(detail?.contentIdentity)
                                } else if detail == nil, story.category == "ai-weekly-events" {
                                    // 等固定正文到达再播放，避免先闪现列表全文摘要、随后倒退到首字。
                                    Text(verbatim: story.summary).hidden().accessibilityHidden(true)
                                } else {
                                    Text(verbatim: story.summary)
                                }
                            }
                                .font(scale.font(size: 17))
                                .foregroundStyle(.secondary)
                                .lineSpacing(5)
                            HStack(spacing: 12) {
                                Label {
                                    Text(verbatim: String(format: String.l10n("dailyRadar.readingTime"), locale: locale, (article?.readingMinutes ?? story.minutes).formatted(.number.locale(locale))))
                                } icon: { Image(systemName: "clock") }
                            }
                            .font(scale.font(size: 11))
                            .foregroundStyle(.secondary)
                            .opacity(headerAppeared || reduceMotion ? 1 : 0)
                            .offset(y: headerAppeared || reduceMotion ? 0 : 12)
                        }
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: headerAppeared)
                        Divider()
                        Group {
                            if let detail, let markdown = detail.markdown {
                                VStack(alignment: .leading, spacing: 28) {
                                    DailyRadarMarkdownView(
                                        markdown: article?.body ?? markdown, identity: detail.contentIdentity,
                                        onLink: openLink, height: $markdownHeight,
                                        onReady: { markdownReady = true }
                                    )
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
                                }
                            } else if failed {
                                ContentUnavailableView {
                                    Label("error.loadFailed", systemImage: "exclamationmark.triangle")
                                } actions: {
                                    Button("action.retry", action: retry)
                                }
                            } else {
                                Color.clear.frame(height: 240)
                            }
                        }
                        // 详情响应到达不等于 WebKit 已排版完成。先挂载正文并收取高度，
                        // 再同步淡出骨架、淡入正文；图片仍各自懒加载，不阻塞文章出现。
                        // 动画只作用于透明度，避免后续图片撑高正文时整篇跟着缩放。
                        .opacity(markdownReady || failed ? 1 : 0)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: markdownReady)
                        .allowsHitTesting(markdownReady || failed)
                        .accessibilityHidden(!markdownReady && !failed)
                        .frame(minHeight: !markdownReady && !failed ? 240 : nil, alignment: .topLeading)
                        .overlay(alignment: .topLeading) {
                            ZStack {
                                if !markdownReady && !failed {
                                    DailyRadarReaderSkeleton()
                                        .transition(.opacity)
                                }
                            }
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: markdownReady)
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                        }
                        .onChange(of: detail?.contentIdentity) { _, _ in
                            // 重试或替换正文时重新等待当前文档，不沿用上一份的就绪信号。
                            if detail == nil {
                                markdownReady = false
                            }
                        }
                    }
                    .frame(maxWidth: DailyRadarReaderLayout.contentMaxWidth(in: availableWidth), alignment: .leading)
                    .padding(.horizontal, DailyRadarReaderLayout.horizontalPadding)
                    .padding(.vertical, 36)
                    .frame(maxWidth: .infinity)
                }
            }
            .coordinateSpace(name: DailyRadarReaderLayout.scrollCoordinateSpace)
            .task(id: story.contentIdentity) {
                await playEntrance()
            }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var article: DailyRadarArticle? {
        detail?.markdown.flatMap(DailyRadarArticle.parse)
    }

    /// 头图先稳定，标题和元信息再短延迟入场；正文与摘要仍沿用原有加载/逐字节奏。
    private func playEntrance() async {
        heroAppeared = false
        headerAppeared = false
        guard !reduceMotion else {
            heroAppeared = true
            headerAppeared = true
            return
        }
        // 先让初始帧完成一次状态提交，避免切换报告时 false→true 被合并成直接显示终态。
        try? await Task.sleep(for: .milliseconds(16))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.28)) {
            heroAppeared = true
        }
        try? await Task.sleep(for: .milliseconds(60))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.24)) {
            headerAppeared = true
        }
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

/// 摘要由编辑时生成，打开只播放已有文本；预留全文和光标高度，避免逐字出现时推动正文。
/// 状态属于本次文章会话，主题和字号变化不重播；减少动态效果时立即展示完整摘要。
private struct DailyRadarArticleSummary: View {
    let summary: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = ""
    @State private var completed = false

    var body: some View {
        Text(verbatim: summary + "▏")
            .hidden()
            .overlay(alignment: .topLeading) {
                Text(verbatim: visible + (completed || reduceMotion ? "" : "▏"))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: summary))
            .task(id: reduceMotion) {
                guard !completed else { return }
                if reduceMotion {
                    visible = summary
                    completed = true
                    return
                }
                // 每 50ms 只追加一个完整字素，避免长摘要成批跳字；光标随文字末尾移动。
                for character in summary {
                    guard !Task.isCancelled else { return }
                    visible.append(character)
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                }
                completed = true
            }
    }
}

/// 正文加载骨架：镜像日报 markdown「段落 + 榜单表格」的排版节奏，
/// 配色与 shimmer 复用中栏 Repo 卡片骨架的共享组件
/// （SkeletonPalette / SkeletonBlock / SkeletonAnimatedPhase，见
/// SkeletonPlaceholderSupport.swift），保证全 App 骨架观感一致。
///
/// 关键约束：
/// - reduceMotion 时 phase 恒 0（由 SkeletonAnimatedPhase 处理），只剩静态占位。
/// - 纯展示：accessibilityHidden + 不接收点击，不进入辅助功能树。
private struct DailyRadarReaderSkeleton: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SkeletonAnimatedPhase { phase in
            VStack(alignment: .leading, spacing: 14) {
                // 引导段三行，末行收窄模拟段尾。
                SkeletonBlock(height: 13, cornerRadius: 4, phase: phase, palette: palette)
                SkeletonBlock(height: 13, cornerRadius: 4, phase: phase, phaseOffset: 0.06, palette: palette)
                SkeletonBlock(height: 13, cornerRadius: 4, phase: phase, phaseOffset: 0.12, palette: palette)
                    .frame(maxWidth: 340, alignment: .leading)
                // 日报核心的榜单表格块：整块占位，圆角对齐 markdown 表格容器。
                SkeletonBlock(height: 132, cornerRadius: 12, phase: phase, phaseOffset: 0.18, palette: palette)
                SkeletonBlock(height: 13, cornerRadius: 4, phase: phase, phaseOffset: 0.24, palette: palette)
                SkeletonBlock(height: 13, cornerRadius: 4, phase: phase, phaseOffset: 0.30, palette: palette)
                    .frame(maxWidth: 260, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 240, alignment: .top)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var palette: SkeletonPalette {
        SkeletonPalette.forColorScheme(colorScheme)
    }
}

/// 阅读区布局统一管理，保证项目面板避让横条，并锁定正文的自适应宽度。
enum DailyRadarReaderLayout {
    /// 供 hero 视差读取滚动偏移；命名常量避免视图重构后误指向其它 ScrollView。
    static let scrollCoordinateSpace = "dailyRadarReaderScroll"
    static let heroHeight: CGFloat = 310
    static let heroParallaxFactor: CGFloat = 0.35
    /// 横条与分隔线共用固定尺寸，工作区据此限制项目面板及遮罩的上边缘。
    static let headerHeight: CGFloat = 52
    static let headerDividerHeight: CGFloat = 1
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
