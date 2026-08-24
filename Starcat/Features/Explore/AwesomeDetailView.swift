//
//  AwesomeDetailView.swift
//  Starcat
//
//  Awesome 右栏详情：复用 Discovery Repo scaffold，并在 README 前展示可审计来源证据。
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

    private var orderedEvidence: [AwesomeEntryEvidence] {
        item.evidence.sorted { lhs, rhs in
            if lhs.source.id == currentSourceID { return true }
            if rhs.source.id == currentSourceID { return false }
            if lhs.source.sortOrder != rhs.source.sortOrder { return lhs.source.sortOrder < rhs.source.sortOrder }
            return lhs.source.displayName.localizedCaseInsensitiveCompare(rhs.source.displayName) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("awesome.detail.sources.title", systemImage: "square.stack.3d.up")
                .font(.headline)

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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}
