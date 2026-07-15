//
//  RAGMetadataSectionHelp.swift
//  Starcat
//
//  RAG 元数据分组的 info 入口与说明 Popover。
//  主面板只保留可扫描的数字，完整统计口径与来源明细在这里按需展示。
//

import SwiftUI

/// 元数据面板中需要解释统计口径的分组；避免把单位和说明重复塞进窄 Inspector 行内。
enum RAGMetadataSectionHelpTopic {
    case artifacts
    case sourceCoverage

    var systemImage: String {
        switch self {
        case .artifacts: return "sparkles"
        case .sourceCoverage: return "square.stack.3d.up"
        }
    }

    var tint: Color {
        switch self {
        case .artifacts: return .purple
        case .sourceCoverage: return .teal
        }
    }

    var keyPrefix: String { "rag.workspace.inspector.metadata.help.\(rawValue)" }

    private var rawValue: String {
        switch self {
        case .artifacts: return "artifacts"
        case .sourceCoverage: return "sourceCoverage"
        }
    }
}

/// 标题旁的 info.circle。Popover 状态限定在按钮自身，避免影响 Inspector 的展开状态。
struct RAGMetadataSectionInfoButton: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let topic: RAGMetadataSectionHelpTopic
    let snapshot: KnowledgeBaseMetadataSnapshot

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(iconFont(size: 12, scale: interfaceScale, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(LocalizedStringKey("\(topic.keyPrefix).open"))
        .popover(isPresented: $isPresented, arrowEdge: .leading) {
            RAGMetadataSectionHelpPopover(topic: topic, snapshot: snapshot)
                .appLocaleEnvironment()
        }
    }
}

/// 复用 Plan 帮助 Popover 的标题、定义、字段明细结构，但内容只呈现本轮元数据快照的聚合事实。
struct RAGMetadataSectionHelpPopover: View {
    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let topic: RAGMetadataSectionHelpTopic
    let snapshot: KnowledgeBaseMetadataSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                definition
                details
            }
            .padding(16)
        }
        .frame(width: 360 * interfaceScale.multiplier, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: topic.systemImage)
                .font(iconFont(size: 12, scale: interfaceScale, weight: .semibold))
                .foregroundStyle(topic.tint)
                .accessibilityHidden(true)
            Text(LocalizedStringKey("\(topic.keyPrefix).title"))
                .font(ragFont(.headline, scale: interfaceScale, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    private var definition: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey("\(topic.keyPrefix).definition.title"))
                .font(ragFont(.caption, scale: interfaceScale, weight: .semibold))
                .foregroundStyle(.primary)
            Text(LocalizedStringKey("\(topic.keyPrefix).definition.body"))
                .font(ragFont(.caption, scale: interfaceScale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var details: some View {
        switch topic {
        case .artifacts:
            detailRows([
                ("rag.workspace.inspector.metadata.help.artifacts.field.scope", localizedInteger(snapshot.projectCount)),
                ("rag.workspace.inspector.metadata.help.artifacts.field.aiSummaries", localizedInteger(snapshot.aiSummaryProjectCount)),
                ("rag.workspace.inspector.metadata.help.artifacts.field.privateNotes", localizedInteger(snapshot.privateNoteProjectCount)),
                ("rag.workspace.inspector.metadata.help.artifacts.field.aiGeneratedNotes", localizedInteger(snapshot.aiGeneratedNoteProjectCount)),
            ])
        case .sourceCoverage:
            VStack(alignment: .leading, spacing: 8) {
                Text("rag.workspace.inspector.metadata.help.sourceCoverage.fields.title")
                    .font(ragFont(.caption, scale: interfaceScale, weight: .semibold))
                    .foregroundStyle(.primary)
                ForEach(snapshot.sourceIndexCoverage, id: \.source.rawValue) { item in
                    detailRow(
                        item.source.titleKey,
                        value: String(
                            format: String.l10n("rag.workspace.inspector.metadata.help.sourceCoverage.valueFormat"),
                            localizedInteger(item.repositoryCount),
                            localizedInteger(item.searchableChunkCount),
                            localizedInteger(item.chunkCount)
                        )
                    )
                }
            }
        }
    }

    private func detailRows(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey("\(topic.keyPrefix).fields.title"))
                .font(ragFont(.caption, scale: interfaceScale, weight: .semibold))
                .foregroundStyle(.primary)
            ForEach(rows, id: \.0) { row in
                detailRow(LocalizedStringKey(row.0), value: row.1)
            }
        }
    }

    private func detailRow(_ title: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(ragFont(.caption, scale: interfaceScale))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(ragFont(.caption, scale: interfaceScale, weight: .semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
    }

    private func localizedInteger(_ value: Int) -> String {
        value.formatted(.number.locale(locale))
    }
}
