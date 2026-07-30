//
//  RAGRepositoryInsightsXMLPopover.swift
//  Starcat
//
//  RAG 仓库洞察引用的只读 XML 全文弹层。正文只来自当前轮内存或通过 hash 校验的历史 Artifact。
//

import SwiftUI

/// 仓库洞察全文沿用 RepoContext 的尺寸与骨架切换，保证两类特殊 XML 证据交互一致。
struct RAGRepositoryInsightsXMLPopoverContent: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale

    let citation: RAGCitation
    let document: RAGRepositoryInsightsDocument

    var body: some View {
        RAGPopoverSkeletonHandoff(contentID: citation.id) {
            RAGXMLLoadingPopoverContent(
                citation: citation,
                titleKey: "rag.workspace.repositoryInsights.xml"
            )
        } content: {
            resolvedContent
        }
    }

    private var resolvedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            RAGCitationChunkSourceHeader(citation: citation)

            Divider()

            Text("rag.workspace.repositoryInsights.xml")
                .font(ragFont(.caption, scale: interfaceScale, weight: .semibold))
                .foregroundStyle(.secondary)

            ScrollView([.horizontal, .vertical]) {
                Text(document.xml)
                    .font(ragFont(.caption2, scale: interfaceScale, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    // XML 必须保持原始缩进和标签边界，禁止按弹层宽度自动折行。
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

    /// 状态栏仅保留复核这份 XML 身份所需的 hash、时间与实际发送 token。
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
        var items = [
            "\(String.l10n("rag.workspace.repositoryInsights.sourceHash")) \(short(snapshot.sourceHash))",
            "\(String.l10n("rag.workspace.repositoryInsights.xmlHash")) \(short(snapshot.xmlHash))",
            "\(String.l10n("rag.workspace.repositoryInsights.tokens")) \(snapshot.sentTokens.formatted(.number.locale(locale)))",
            snapshot.wasProjected
                ? String.l10n("rag.workspace.repositoryInsights.projection.projected")
                : String.l10n("rag.workspace.repositoryInsights.projection.original"),
        ]
        if let generatedAt = snapshot.generatedAt {
            items.insert(
                generatedAt.formatted(
                    Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
                ),
                at: 0
            )
        }
        return items
    }

    private func short(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        return String(value.prefix(12))
    }
}
