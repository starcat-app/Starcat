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

/// 命中分片全文：顶部来源头（logo + 全名 + 来源·路径）+ Markdown 渲染正文 + 底部状态栏。
struct RAGCitationChunkPopoverContent: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let citation: RAGCitation
    let chunk: RAGChunk

    var body: some View {
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
                configuration.label
                    .relativeLineSpacing(.em(0.12))
                    .markdownMargin(top: .em(0.2), bottom: .em(0.55))
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
private struct RAGCitationChunkSourceHeader: View {
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

/// 加载中占位：先画出来源头，正文区转圈。
struct RAGCitationChunkLoadingPopoverContent: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let citation: RAGCitation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RAGCitationChunkSourceHeader(citation: citation)
            Divider()
            ProgressView()
                .controlSize(.regular)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        onDismiss: @escaping () -> Void
    ) {
        closeWithoutNotifying()
        self.onDismiss = onDismiss

        let root = Self.rootView(
            citation: citation,
            chunk: chunk,
            isMissing: isMissing,
            interfaceScale: interfaceScale
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
        interfaceScale: InterfaceScale
    ) {
        guard popover?.isShown == true else { return }
        let root = Self.rootView(
            citation: citation,
            chunk: chunk,
            isMissing: isMissing,
            interfaceScale: interfaceScale
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
        interfaceScale: InterfaceScale
    ) -> AnyView {
        if let chunk {
            return AnyView(
                RAGCitationChunkPopoverContent(citation: citation, chunk: chunk)
                    .environment(\.starcatInterfaceScale, interfaceScale)
            )
        }
        if isMissing {
            return AnyView(
                RAGCitationChunkMissingPopoverContent(citation: citation)
                    .environment(\.starcatInterfaceScale, interfaceScale)
            )
        }
        return AnyView(
            RAGCitationChunkLoadingPopoverContent(citation: citation)
                .environment(\.starcatInterfaceScale, interfaceScale)
        )
    }
}
