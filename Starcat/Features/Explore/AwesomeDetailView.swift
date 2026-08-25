//
//  AwesomeDetailView.swift
//  Starcat
//
//  Awesome 右栏详情：复用 Discovery Repo scaffold，并在 README 前展示可审计来源证据。
//  证据区默认折叠（整行点击展开），避免挤占 README 阅读高度。
//

import SwiftUI

struct AwesomeDetailView: View {
    let store: AwesomeStore

    var body: some View {
        if let item = store.selectedRepository {
            DiscoveryDetailView(
                item: item.discoveryDTO,
                supplementalHeader: AnyView(AwesomeEvidenceHeader(item: item, currentSourceID: store.selectedSourceID))
            )
        } else {
            DiscoveryDetailView(item: nil)
        }
    }
}

private struct AwesomeEvidenceHeader: View {
    let item: AwesomeRepositoryItem
    let currentSourceID: String?

    /// 默认折叠，把右栏视口让给 README；需要核对条目时再展开。
    @State private var isExpanded = false
    @Environment(\.starcatReduceMotion) private var reduceMotion

    private var orderedEvidence: [AwesomeEntryEvidence] {
        item.evidence.sorted { lhs, rhs in
            if lhs.source.id == currentSourceID { return true }
            if rhs.source.id == currentSourceID { return false }
            if lhs.source.sortOrder != rhs.source.sortOrder { return lhs.source.sortOrder < rhs.source.sortOrder }
            return lhs.source.displayName.localizedCaseInsensitiveCompare(rhs.source.displayName) == .orderedAscending
        }
    }

    /// 折叠时仍显示当前来源名，避免证据区收起来后完全不知道从哪进来的。
    private var collapsedSourceName: String? {
        orderedEvidence.first(where: { $0.source.id == currentSourceID })?.source.displayName
            ?? orderedEvidence.first?.source.displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up")
                        .foregroundStyle(.secondary)
                    Text("awesome.detail.sources.title")
                        .font(.headline)
                    if orderedEvidence.count > 1 {
                        Text(orderedEvidence.count, format: .number)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if !isExpanded, let collapsedSourceName {
                        Text(verbatim: collapsedSourceName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            if isExpanded {
                evidenceList
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var evidenceList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(orderedEvidence.enumerated()), id: \.element.source.id) { _, evidence in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(evidence.source.displayName)
                            .font(.subheadline.weight(evidence.source.id == currentSourceID ? .semibold : .regular))
                        if evidence.source.id == currentSourceID {
                            Text("awesome.detail.currentSource")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !evidence.sectionPath.isEmpty {
                        Text(String(format: String.l10n("awesome.detail.sectionFormat"), evidence.sectionPath.joined(separator: " / ")))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let description = evidence.entryDescription, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    if let url = evidence.sourceAnchorURL {
                        Link(destination: url) {
                            Label("awesome.detail.openSourceEntry", systemImage: "arrow.up.right.square")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
