//
//  RAGRepoContextXMLPopover.swift
//  Starcat
//
//  RepoContext XML 全文弹层：来源头、可滚动 XML 与审计状态栏。
//

import SwiftUI

/// 两类特殊 XML 都比普通命中分片更依赖横向阅读，因此共享较宽画布与三段式高度。
enum RAGXMLPopoverMetrics {
    static let width: CGFloat = 680
    static let height: CGFloat = 520
}

/// 项目上下文全文：顶部确认来源，中部核对 XML，底部快速复核实际发送版本。
struct RAGRepoContextXMLPopoverContent: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let citation: RAGCitation
    let document: RAGRepoContextDocument

    var body: some View {
        RAGPopoverSkeletonHandoff(contentID: citation.id) {
            RAGXMLLoadingPopoverContent(
                citation: citation,
                titleKey: "rag.workspace.repoContext.xml"
            )
        } content: {
            resolvedContent
        }
    }

    private var resolvedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            RAGCitationChunkSourceHeader(citation: citation)

            Divider()

            Text("rag.workspace.repoContext.xml")
                .font(ragFont(.caption, scale: interfaceScale, weight: .semibold))
                .foregroundStyle(.secondary)

            ScrollView([.horizontal, .vertical]) {
                Text(document.xml)
                    .font(ragFont(.caption2, scale: interfaceScale, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    // XML 不能按 popover 宽度重排，否则行号、缩进和标签边界难以核对。
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            statusBar
        }
        .padding(14)
        .frame(
            width: interfaceScale.scaled(RAGXMLPopoverMetrics.width),
            height: interfaceScale.scaled(RAGXMLPopoverMetrics.height),
            alignment: .topLeading
        )
        .appLocaleEnvironment()
    }

    /// 状态栏只放核对完整 XML 时仍有用的版本事实；详细字段继续保留在右侧引用卡片中。
    private var statusBar: some View {
        HStack(spacing: 6) {
            ForEach(Array(statusItems.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Text(verbatim: "·")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(verbatim: item)
                    .lineLimit(1)
            }
        }
        .font(ragFont(.caption, scale: interfaceScale).monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var statusItems: [String] {
        let snapshot = document.snapshot
        return [
            "\(String.l10n("rag.workspace.repoContext.commit")) \(snapshot.shortCommitSHA)",
            "\(String.l10n("rag.workspace.repoContext.hash")) \(snapshot.shortContentHash)",
            "\(String.l10n("rag.workspace.repoContext.tokens")) \(snapshot.sentTokens.formatted())",
            snapshot.cacheHit
                ? String.l10n("rag.workspace.repoContext.cache.hit")
                : String.l10n("rag.workspace.repoContext.cache.generated"),
            snapshot.wasProjected
                ? String.l10n("rag.workspace.repoContext.projection.projected")
                : String.l10n("rag.workspace.repoContext.projection.original")
        ]
    }
}

/// 特殊 XML 与普通分片共用同一交接节奏；画布更宽，因此增加骨架行数，
/// 让加载态在 680pt popover 中仍能表达真实正文密度而不是一块空白。
struct RAGXMLLoadingPopoverContent: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme

    let citation: RAGCitation
    let titleKey: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RAGCitationChunkSourceHeader(citation: citation)
            Divider()

            Text(titleKey)
                .font(ragFont(.caption, scale: interfaceScale, weight: .semibold))
                .foregroundStyle(.secondary)

            SkeletonAnimatedPhase { phase in
                let palette = SkeletonPalette.forColorScheme(colorScheme)
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(0..<11, id: \.self) { index in
                        SkeletonBlock(
                            maxWidth: index == 3 || index == 8
                                ? interfaceScale.scaled(470)
                                : nil,
                            height: interfaceScale.scaled(9),
                            cornerRadius: 3,
                            phase: phase,
                            phaseOffset: Double(index) * 0.055,
                            palette: palette
                        )
                    }
                    Spacer(minLength: 0)
                    Divider()
                    HStack(spacing: 8) {
                        ForEach(0..<4, id: \.self) { index in
                            SkeletonBlock(
                                width: interfaceScale.scaled(index.isMultiple(of: 2) ? 82 : 110),
                                height: interfaceScale.scaled(8),
                                cornerRadius: 3,
                                phase: phase,
                                phaseOffset: Double(index) * 0.1,
                                palette: palette
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityLabel(Text("rag.workspace.conversation.loading"))
        }
        .padding(14)
        .frame(
            width: interfaceScale.scaled(RAGXMLPopoverMetrics.width),
            height: interfaceScale.scaled(RAGXMLPopoverMetrics.height),
            alignment: .topLeading
        )
        .appLocaleEnvironment()
    }
}

extension RAGRepoContextSnapshot {
    /// Git commit 遵循 Git UI 惯例取 7 位；缺失时保留统一占位符。
    var shortCommitSHA: String {
        Self.shortHash(commitSHA, length: 7)
    }

    /// SHA-256 内容哈希取 12 位，在可扫描性与人工比对辨识度之间取平衡。
    var shortContentHash: String {
        Self.shortHash(contentHash, length: 12)
    }

    private static func shortHash(_ value: String?, length: Int) -> String {
        guard let value, !value.isEmpty else { return "-" }
        return String(value.prefix(length))
    }
}
