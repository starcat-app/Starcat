//
//  FollowGraphCacheStatisticsView.swift
//  Starcat
//
//  设置页只读统计。按当前账户读取本地快照，不采集关系，也不提供清理按钮。
//

import SwiftUI

/// 独立小节避免把图谱加载状态耦合到设置页的全局缓存清理动作。
struct FollowGraphCacheStatisticsView: View {
    @Environment(AuthSession.self) private var auth
    @Environment(\.locale) private var locale
    @State private var snapshots: [FollowGraphRelation: FollowGraphSnapshot] = [:]
    @State private var sizes: [FollowGraphRelation: Int64] = [:]

    var body: some View {
        Section {
            ForEach(FollowGraphRelation.allCases, id: \.self) { relation in
                Text(String.l10n(relation.titleKey)).font(.headline)
                if let snapshot = snapshots[relation] {
                    LabeledContent("followGraph.cache.size", value:
                        (sizes[relation] ?? 0).formatted(.byteCount(style: .file).locale(locale)))
                    LabeledContent("followGraph.status.counts", value:
                        "\(snapshot.nodes.count.formatted(.number.locale(locale))) · \(snapshot.edges.count.formatted(.number.locale(locale)))")
                    LabeledContent("followGraph.cache.saved") {
                        Text(snapshot.savedAt, format: .dateTime.year().month().day().hour().minute().locale(locale))
                    }
                } else {
                    Text("followGraph.cache.empty").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("followGraph.title")
        } footer: {
            Text("followGraph.status.snapshot")
        }
        .task(id: auth.state.user?.id) {
            snapshots = [:]
            sizes = [:]
            guard let id = auth.state.user?.id else { return }
            for relation in FollowGraphRelation.allCases {
                let value = await FollowGraphDiskCache.shared.load(account: String(id), relation: relation)
                let size = await FollowGraphDiskCache.shared.bytes(account: String(id), relation: relation)
                guard !Task.isCancelled, auth.state.user?.id == id else { return }
                snapshots[relation] = value
                sizes[relation] = size
            }
        }
    }
}
