//
//  RAGRepoContextXMLPopover.swift
//  Starcat
//
//  RepoContext XML 全文弹层：来源头、可滚动 XML 与审计状态栏。
//

import SwiftUI

/// XML 比普通命中分片更依赖横向阅读，因此保留较宽画布，同时沿用证据 popover 的三段式高度。
private enum RAGRepoContextXMLPopoverMetrics {
    static let width: CGFloat = 680
    static let height: CGFloat = 520
}

/// 项目上下文全文：顶部确认来源，中部核对 XML，底部快速复核实际发送版本。
struct RAGRepoContextXMLPopoverContent: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let citation: RAGCitation
    let document: RAGRepoContextDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sourceHeader

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
            width: interfaceScale.scaled(RAGRepoContextXMLPopoverMetrics.width),
            height: interfaceScale.scaled(RAGRepoContextXMLPopoverMetrics.height),
            alignment: .topLeading
        )
        .appLocaleEnvironment()
    }

    /// 与命中分片弹层同构：第一行识别仓库，第二行说明证据类型和 context.xml 版本。
    private var sourceHeader: some View {
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
