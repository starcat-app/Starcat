//
//  RAGCitationChips.swift
//  Starcat
//
//  RAG 回答底部引用芯片与紧凑换行布局。
//

import AppKit
import SwiftUI

/// 回答底部引用芯片：默认 3 条，超出折叠；底色按 `owner/repo` 稳定 hash，明暗皆淡色。
/// 文案只保留 `Sn · repo`；同 repo 不同分片靠彩色 source 图标区分，不堆 sectionTitle。
/// 点击只定位右侧证据，不弹分片 popover（popover 仅改正文蓝色 S1 链接）。
struct RAGCitationChipsRow: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion

    let citations: [RAGCitation]
    let onSelectCitation: (RAGCitation) -> Void

    /// 首屏只露 3 条，避免长回答底部被芯片墙占满。
    private static let previewLimit = 3

    @State private var isExpanded = false

    private var visibleCitations: [RAGCitation] {
        if isExpanded || citations.count <= Self.previewLimit {
            return citations
        }
        return Array(citations.prefix(Self.previewLimit))
    }

    private var hiddenCount: Int {
        max(0, citations.count - Self.previewLimit)
    }

    var body: some View {
        RAGFlowLayout(spacing: 7) {
            ForEach(visibleCitations) { citation in
                Button {
                    onSelectCitation(citation)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: citation.source.systemImageName)
                            .font(interfaceScale.font(size: 10, weight: .semibold))
                            .foregroundStyle(citation.source.tintColor)
                        Text("\(citation.marker) ·")
                            // captionSmall(11) 比正文 body(13) 再小一档，避免底部引用抢视线。
                            .font(interfaceScale.font(.captionSmall, weight: .medium))
                            .foregroundStyle(.primary)
                        if citation.source == .knowledgeBaseMetadata {
                            Text(citation.source.titleKey)
                                .font(interfaceScale.font(.captionSmall, weight: .medium))
                                .lineLimit(1)
                        } else {
                            // owner logo 走 Kingfisher 缓存；芯片内 12pt、无描边，避免挤爆短芯片。
                            RepoIdentityLabel(
                                fullName: citation.repoFullName,
                                avatarSize: 12,
                                font: interfaceScale.font(.captionSmall, weight: .medium),
                                spacing: 4,
                                showAvatarBorder: false
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RAGCitationChipPalette.background(
                            for: citation.repoLanguage,
                            fallbackRepoFullName: citation.localizedIdentityTitle
                        ),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(chipHelp(for: citation))
            }

            if hiddenCount > 0 {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Group {
                        if isExpanded {
                            Text("rag.workspace.citations.collapse")
                        } else {
                            Text(String(format: String.l10n("rag.workspace.citations.moreFormat"), hiddenCount))
                        }
                    }
                    .font(interfaceScale.font(.captionSmall, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// tooltip 仍带 section，方便悬停看具体分片；芯片本体保持短。
    private func chipHelp(for citation: RAGCitation) -> String {
        let section = citation.sectionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if section.isEmpty {
            return "\(citation.marker) · \(citation.localizedIdentityTitle)"
        }
        return "\(citation.marker) · \(citation.localizedIdentityTitle) · \(citation.localizedSectionTitle)"
    }
}

/// 引用 chip 优先复用仓库主语言色；语言缺失时按 `owner/repo` 回退稳定低饱和色盘。
enum RAGCitationChipPalette {
    private static let swatches: [(hue: CGFloat, satLight: CGFloat, briLight: CGFloat, satDark: CGFloat, briDark: CGFloat)] = [
        (210, 0.26, 0.94, 0.28, 0.30), // soft blue
        (168, 0.24, 0.93, 0.26, 0.29), // teal
        (145, 0.22, 0.93, 0.24, 0.29), // green
        (32, 0.28, 0.95, 0.30, 0.31),  // sand
        (195, 0.24, 0.94, 0.26, 0.30), // cyan
        (250, 0.18, 0.94, 0.22, 0.31), // muted indigo
        (350, 0.18, 0.95, 0.22, 0.31), // soft rose
        (48, 0.26, 0.95, 0.28, 0.31),  // soft gold
    ]

    static func background(for language: String?, fallbackRepoFullName repoFullName: String) -> Color {
        if let language = language?.trimmingCharacters(in: .whitespacesAndNewlines),
           !language.isEmpty {
            // 与 RepoRowSurface 使用同一个 LanguageColor 单一来源；低透明度只承担
            // 项目辨识，不把引用 chip 提升成选中态或状态色。
            return LanguageColor.color(for: language).opacity(0.14)
        }
        let swatch = swatches[stableIndex(for: repoFullName)]
        return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(
                calibratedHue: swatch.hue / 360,
                saturation: isDark ? swatch.satDark : swatch.satLight,
                brightness: isDark ? swatch.briDark : swatch.briLight,
                alpha: 1
            )
        }))
    }

    private static func stableIndex(for repoFullName: String) -> Int {
        // djb2：同一仓库跨会话/跨消息颜色一致。
        var hash: UInt64 = 5381
        for byte in repoFullName.lowercased().utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return Int(hash % UInt64(swatches.count))
    }
}

/// 紧凑换行布局：Inspector chips / 输入框上方的 repo·附件 chip 共用，随容器宽度折行。
struct RAGFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews)
        for (index, item) in arrangement.items.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                proposal: ProposedViewSize(width: item.size.width, height: item.size.height)
            )
        }
    }

    /// FlowLayout 不向父容器声明自定义对齐线。SwiftUI 的默认实现会为求显式对齐值
    /// 再次遍历全部 child geometry，并在嵌套 ScrollView / Stack 中反复进入
    /// `placeSubviews`。Agent 流式更新曾因此把主线程永久锁在 AttributeGraph 布局事务中。
    func explicitAlignment(
        of guide: HorizontalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGFloat? {
        nil
    }

    /// 与水平对齐一致，明确返回 nil，交给父容器按 frame alignment 放置整个 FlowLayout。
    func explicitAlignment(
        of guide: VerticalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGFloat? {
        nil
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, items: [(origin: CGPoint, size: CGSize)]) {
        let maxWidth = proposal.width ?? .infinity
        var items: [(origin: CGPoint, size: CGSize)] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            // 单颗 chip 不应宽过容器，否则无法折行时仍会横向溢出。
            let size = subview.sizeThatFits(
                ProposedViewSize(width: maxWidth == .infinity ? nil : maxWidth, height: nil)
            )
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            items.append((CGPoint(x: x, y: y), size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        return (CGSize(width: min(usedWidth, maxWidth), height: y + lineHeight), items)
    }
}
