//
//  RAGCitationChunkPopover.swift
//  Starcat
//
//  「命中的分片」全文弹层：证据区同款来源头 + Markdown 正文；
//  正文 S1 用 NSPopover 锚在点击位置。
//

import AppKit
import MarkdownUI
import SwiftUI

/// 与右侧证据「命中的分片」popover 对齐的固定尺寸，避免 SwiftUI `.popover` 挂在大段
/// Markdown 上时被系统压成窄条。略增高以容纳来源头 + 底部元数据状态栏。
enum RAGCitationChunkPopoverMetrics {
    static let width: CGFloat = 400
    static let height: CGFloat = 460
}

/// Popover 大正文的统一两阶段交接：先提交轻量骨架，再把正文挂在骨架下完成首次布局，
/// 最后淡出骨架。这样点击事务不会和大段 Markdown / XML 的首轮布局挤在同一帧。
///
/// `contentID` 变化会取消旧任务并重新从骨架开始，避免连续切换引用时旧交接状态泄漏。
struct RAGPopoverSkeletonHandoff<Placeholder: View, Content: View>: View {
    @Environment(\.starcatReduceMotion) private var reduceMotion

    let contentID: UUID
    private let placeholder: () -> Placeholder
    private let content: () -> Content

    @State private var phase: Phase = .placeholder

    private enum Phase: Equatable {
        case placeholder
        case mounted
        case revealed
    }

    init(
        contentID: UUID,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.contentID = contentID
        self.placeholder = placeholder
        self.content = content
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if phase != .placeholder {
                content()
                    .opacity(phase == .revealed ? 1 : 0)
                    .allowsHitTesting(phase == .revealed)
                    .accessibilityHidden(phase != .revealed)
            }

            if phase != .revealed {
                placeholder()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .task(id: contentID) {
            await performHandoff()
        }
    }

    /// 至少把骨架提交一个显示帧，再挂载正文；正文完成首次布局后才开始视觉交接。
    /// Reduce Motion 仍保留分帧挂载来保护响应性，只关闭淡入淡出动画。
    @MainActor
    private func performHandoff() async {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            phase = .placeholder
        }

        do {
            try await Task.sleep(for: .milliseconds(16))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        withTransaction(transaction) {
            phase = .mounted
        }
        await Task.yield()
        guard !Task.isCancelled else { return }

        if reduceMotion {
            withTransaction(transaction) {
                phase = .revealed
            }
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                phase = .revealed
            }
        }
    }
}

/// 命中分片全文：顶部来源头（logo + 全名 + 来源·路径）+ Markdown 渲染正文 + 底部状态栏。
struct RAGCitationChunkPopoverContent: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let citation: RAGCitation
    let chunk: RAGChunk

    var body: some View {
        RAGPopoverSkeletonHandoff(contentID: citation.id) {
            RAGCitationChunkLoadingPopoverContent(citation: citation)
        } content: {
            resolvedContent
        }
    }

    private var resolvedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            RAGCitationChunkSourceHeader(citation: citation)

            Divider()

            Text("rag.workspace.inspector.chunkPreview")
                .font(ragFont(.caption, scale: interfaceScale, weight: .semibold))
                .foregroundStyle(.secondary)

            ScrollView {
                Markdown(chunk.content)
                    .markdownTheme(chunkMarkdownTheme(scale: interfaceScale))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            RAGCitationChunkStatusBar(citation: citation, chunk: chunk)
        }
        .padding(14)
        .frame(
            width: interfaceScale.scaled(RAGCitationChunkPopoverMetrics.width),
            height: interfaceScale.scaled(RAGCitationChunkPopoverMetrics.height),
            alignment: .topLeading
        )
        // 分片里的外链直接打开浏览器；忽略 starcat-rag 以免嵌套弹层。
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "http" || url.scheme == "https" else { return .discarded }
            NSWorkspace.shared.open(url)
            return .handled
        })
        .appLocaleEnvironment()
    }

    /// 弹层内 Markdown：比回答正文更紧，适合 400pt 宽的证据窗口。
    private func chunkMarkdownTheme(scale: InterfaceScale) -> Theme {
        Theme()
            .text {
                ForegroundColor(.primary)
                FontSize(scale.scaled(12))
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.92))
                BackgroundColor(.secondary.opacity(0.12))
            }
            .link {
                ForegroundColor(.accentColor)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.4), bottom: .em(0.25))
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(scale.scaled(15))
                    }
            }
            .heading2 { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.35), bottom: .em(0.2))
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(scale.scaled(14))
                    }
            }
            .heading3 { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.3), bottom: .em(0.15))
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(scale.scaled(13))
                    }
            }
            .paragraph { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.18))
                    .markdownMargin(top: .zero, bottom: .em(0.55))
            }
            .list { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.1), bottom: .em(0.55))
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.25))
            }
            .codeBlock { configuration in
                // 分片内容可能来自 README 配置样例；代码块需要独立容器，否则窄 popover
                // 里 fenced code 会和正文混在一起，截图里的 YAML 就属于这种情况。
                ScrollView(.horizontal, showsIndicators: true) {
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .relativeLineSpacing(.em(0.12))
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.92))
                            BackgroundColor(nil)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                }
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.22), lineWidth: 0.5)
                )
                .markdownMargin(top: .em(0.2), bottom: .em(0.55))
            }
            // 默认 Theme 表格几乎无内边距 + 全网格描边，在 400pt 窄窗里会挤成截图那样。
            // 与回答正文主题（RAGMarkdownText.ragAnswerTheme）对齐：横线分隔 + 斑马纹 +
            // 表头加重，宽表由外层横向滚动而不是把列压扁；单元格内边距按窄窗收紧。
            .table { configuration in
                ScrollView(.horizontal, showsIndicators: true) {
                    configuration.label
                        // 让表格按内容固有宽度布局；过宽时由外层横向滚动，不把列压扁。
                        .fixedSize(horizontal: true, vertical: true)
                        .markdownTableBorderStyle(
                            TableBorderStyle(
                                .horizontalBorders,
                                color: Color.secondary.opacity(0.35),
                                width: 0.5
                            )
                        )
                        .markdownTableBackgroundStyle(
                            .alternatingRows(
                                Color.clear,
                                Color.primary.opacity(0.04),
                                header: Color.primary.opacity(0.08)
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.secondary.opacity(0.22), lineWidth: 0.5)
                        )
                }
                .markdownMargin(top: .em(0.2), bottom: .em(0.55))
            }
            .tableCell { configuration in
                configuration.label
                    .markdownTextStyle {
                        if configuration.row == 0 {
                            FontWeight(.semibold)
                        }
                        // 背景交给 tableBackgroundStyle，避免 Text 再铺一层抢斑马纹。
                        BackgroundColor(nil)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .relativeLineSpacing(.em(0.16))
            }
    }
}

/// 底部状态栏：marker / token / 字数 / 命中方式 / 向量相似度；截断靠右。
///
/// 只放「看全文时仍有用、且证据头没展示」的字段；section / repo 已在顶部，不再重复。
/// 综合检索分故意不放这里——会和向量相似度混淆；要看融合分去右侧证据详情。
/// 创建时间不加：400pt 宽不够，再塞会被挤掉或省略。
private struct RAGCitationChunkStatusBar: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale

    let citation: RAGCitation
    let chunk: RAGChunk

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(Array(statusItems.enumerated()), id: \.offset) { index, item in
                    if index > 0 {
                        statusSeparator
                    }
                    Group {
                        if let helpKey = item.helpKey {
                            statusItem(item.text, monospaced: item.monospaced)
                                .help(LocalizedStringKey(helpKey))
                        } else {
                            statusItem(item.text, monospaced: item.monospaced)
                        }
                    }
                }
            }
            .lineLimit(1)

            Spacer(minLength: 8)

            if chunk.isTruncated {
                Label("rag.workspace.inspector.chunkTruncated", systemImage: "scissors")
                    .labelStyle(.iconOnly)
                    .font(ragFont(.caption, scale: interfaceScale))
                    .foregroundStyle(.orange)
                    .help("rag.workspace.inspector.chunkTruncated")
            }
        }
        .font(ragFont(.caption, scale: interfaceScale))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var statusItems: [StatusItem] {
        var items: [StatusItem] = [
            .init(text: citation.marker, monospaced: true),
            .init(
                text: String(
                    format: String.l10n("rag.browser.chunks.tokenCountFormat"),
                    chunk.tokenCount
                ),
                monospaced: true
            ),
            .init(
                text: String(
                    format: String.l10n("rag.workspace.inspector.chunkPopover.charCountFormat"),
                    chunk.content.count
                ),
                monospaced: true
            ),
            .init(text: citation.hitKind.rawValue),
        ]

        // keyword-only 命中没有向量分；有才展示，避免把综合检索分误当成相似度。
        if let similarity = citation.vectorSimilarity {
            items.append(
                .init(
                    text: String(format: "%.3f", locale: locale, similarity),
                    monospaced: true,
                    helpKey: "rag.workspace.inspector.vectorSimilarity"
                )
            )
        }

        return items
    }

    private var statusSeparator: some View {
        Text(verbatim: "·")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private func statusItem(_ text: String, monospaced: Bool = false) -> some View {
        Text(verbatim: text)
            .font(
                monospaced
                    ? ragFont(.caption, scale: interfaceScale).monospacedDigit()
                    : ragFont(.caption, scale: interfaceScale)
            )
    }

    private struct StatusItem {
        let text: String
        var monospaced: Bool = false
        var helpKey: String? = nil
    }
}

/// 与右侧证据列表行同构：第一行 logo+全名，第二行 source 图标 +「来源 · section」。
struct RAGCitationChunkSourceHeader: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let citation: RAGCitation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            RepoIdentityLabel(
                fullName: citation.repoFullName,
                avatarSize: 16,
                font: ragFont(.callout, scale: interfaceScale, weight: .semibold),
                spacing: 6,
                showAvatarBorder: false
            )
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: citation.source.systemImageName)
                    .font(iconFont(size: 11, scale: interfaceScale, weight: .semibold))
                    .foregroundStyle(citation.source.tintColor)
                (Text(citation.source.titleKey) + Text(" · \(citation.sectionTitle)"))
                    .font(ragFont(.caption2, scale: interfaceScale))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 引用无 chunk 时的空态；仍展示来源头，方便确认点到了哪条。
struct RAGCitationChunkMissingPopoverContent: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let citation: RAGCitation

    var body: some View {
        RAGPopoverSkeletonHandoff(contentID: citation.id) {
            RAGCitationChunkLoadingPopoverContent(citation: citation)
        } content: {
            missingContent
        }
    }

    private var missingContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            RAGCitationChunkSourceHeader(citation: citation)
            Divider()
            Label("rag.workspace.inspector.chunkMissing", systemImage: "exclamationmark.triangle.fill")
                .font(ragFont(.caption, scale: interfaceScale))
                .foregroundStyle(.orange)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(
            width: RAGCitationChunkPopoverMetrics.width,
            height: RAGCitationChunkPopoverMetrics.height,
            alignment: .topLeading
        )
        .appLocaleEnvironment()
    }
}

/// 加载中占位：来源事实立即可见，正文与状态栏使用共享 shimmer 骨架。
struct RAGCitationChunkLoadingPopoverContent: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme

    let citation: RAGCitation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RAGCitationChunkSourceHeader(citation: citation)
            Divider()

            Text("rag.workspace.inspector.chunkPreview")
                .font(ragFont(.caption, scale: interfaceScale, weight: .semibold))
                .foregroundStyle(.secondary)

            SkeletonAnimatedPhase { phase in
                let palette = SkeletonPalette.forColorScheme(colorScheme)
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(0..<8, id: \.self) { index in
                        SkeletonBlock(
                            maxWidth: index == 2 || index == 6
                                ? interfaceScale.scaled(250)
                                : nil,
                            height: interfaceScale.scaled(9),
                            cornerRadius: 3,
                            phase: phase,
                            phaseOffset: Double(index) * 0.07,
                            palette: palette
                        )
                    }
                    Spacer(minLength: 0)
                    Divider()
                    HStack(spacing: 8) {
                        SkeletonBlock(
                            width: interfaceScale.scaled(64),
                            height: interfaceScale.scaled(8),
                            cornerRadius: 3,
                            phase: phase,
                            palette: palette
                        )
                        SkeletonBlock(
                            width: interfaceScale.scaled(92),
                            height: interfaceScale.scaled(8),
                            cornerRadius: 3,
                            phase: phase,
                            phaseOffset: 0.12,
                            palette: palette
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityLabel(Text("rag.workspace.conversation.loading"))
        }
        .padding(14)
        .frame(
            width: RAGCitationChunkPopoverMetrics.width,
            height: RAGCitationChunkPopoverMetrics.height,
            alignment: .topLeading
        )
        .appLocaleEnvironment()
    }
}

/// 正文蓝色 S1 专用：在点击屏幕坐标弹出固定尺寸 NSPopover，跟随点击点而不是整段 Markdown。
///
/// SwiftUI `.popover` 挂在整段 `RAGMarkdownText` 上时，锚点落在块级中心且尺寸常被压扁；
/// MarkdownUI 的 link 又不是独立 View，无法给单个 S1 挂 popover。因此走 AppKit 锚点。
@MainActor
final class RAGCitationChunkNSPopoverPresenter: NSObject, NSPopoverDelegate {
    static let shared = RAGCitationChunkNSPopoverPresenter()

    private var popover: NSPopover?
    private var anchorView: NSView?
    private var hostingController: NSHostingController<AnyView>?
    private var onDismiss: (() -> Void)?

    /// - Parameters:
    ///   - screenPoint: `NSEvent.mouseLocation`（屏幕坐标，左下原点）。
    ///   - interfaceScale: 注入 popover 内环境，与工作台字号一致。
    func present(
        citation: RAGCitation,
        chunk: RAGChunk?,
        isMissing: Bool,
        screenPoint: NSPoint,
        interfaceScale: InterfaceScale,
        settings: AppSettings,
        onDismiss: @escaping () -> Void
    ) {
        closeWithoutNotifying()
        self.onDismiss = onDismiss

        let root = Self.rootView(
            citation: citation,
            chunk: chunk,
            isMissing: isMissing,
            interfaceScale: interfaceScale,
            settings: settings
        )
        let hosting = NSHostingController(rootView: root)
        hosting.view.frame = NSRect(
            origin: .zero,
            size: NSSize(
                width: RAGCitationChunkPopoverMetrics.width,
                height: RAGCitationChunkPopoverMetrics.height
            )
        )
        hostingController = hosting

        let popover = NSPopover()
        popover.contentSize = NSSize(
            width: RAGCitationChunkPopoverMetrics.width,
            height: RAGCitationChunkPopoverMetrics.height
        )
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hosting
        popover.delegate = self
        self.popover = popover

        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible),
              let contentView = window.contentView else {
            closeWithoutNotifying()
            return
        }

        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = contentView.convert(windowPoint, from: nil)
        let anchor = NSView(frame: NSRect(x: localPoint.x, y: localPoint.y, width: 2, height: 2))
        anchor.wantsLayer = false
        contentView.addSubview(anchor)
        anchorView = anchor

        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    /// chunk 异步到达后替换内容，保持同一弹层与锚点。
    func update(
        citation: RAGCitation,
        chunk: RAGChunk?,
        isMissing: Bool,
        interfaceScale: InterfaceScale,
        settings: AppSettings
    ) {
        guard popover?.isShown == true else { return }
        let root = Self.rootView(
            citation: citation,
            chunk: chunk,
            isMissing: isMissing,
            interfaceScale: interfaceScale,
            settings: settings
        )
        hostingController?.rootView = root
    }

    func dismiss() {
        // 主动关闭时不再回调 onDismiss，避免与 ViewModel.dismiss 互相重入。
        onDismiss = nil
        popover?.delegate = nil
        popover?.close()
        popover = nil
        hostingController = nil
        cleanupAnchor()
    }

    func popoverDidClose(_ notification: Notification) {
        cleanupAnchor()
        popover = nil
        hostingController = nil
        let callback = onDismiss
        onDismiss = nil
        callback?()
    }

    private func closeWithoutNotifying() {
        onDismiss = nil
        popover?.delegate = nil
        popover?.close()
        popover = nil
        hostingController = nil
        cleanupAnchor()
    }

    private func cleanupAnchor() {
        anchorView?.removeFromSuperview()
        anchorView = nil
    }

    private static func rootView(
        citation: RAGCitation,
        chunk: RAGChunk?,
        isMissing: Bool,
        interfaceScale: InterfaceScale,
        settings: AppSettings
    ) -> AnyView {
        if let chunk {
            return AnyView(
                RAGCitationChunkPopoverContent(citation: citation, chunk: chunk)
                    .environment(\.starcatInterfaceScale, interfaceScale)
                    .starcatAnimationOverride()
                    .environment(settings)
            )
        }
        if isMissing {
            return AnyView(
                RAGCitationChunkMissingPopoverContent(citation: citation)
                    .environment(\.starcatInterfaceScale, interfaceScale)
                    .starcatAnimationOverride()
                    .environment(settings)
            )
        }
        return AnyView(
            RAGCitationChunkLoadingPopoverContent(citation: citation)
                .environment(\.starcatInterfaceScale, interfaceScale)
                .starcatAnimationOverride()
                .environment(settings)
        )
    }
}
