//
//  StarcatContributionProvider.swift
//  StarcatWidgets
//
//  四个 GitHub 贡献 Widget 共用的只读时间线提供器。
//

import WidgetKit

/// 贡献 Widget 只消费主应用发布的 App Group 快照，不在 Extension 内访问网络或 Token。
struct StarcatContributionProvider: TimelineProvider {
    func placeholder(in context: Context) -> StarcatWidgetEntry {
        .placeholder
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (StarcatWidgetEntry) -> Void
    ) {
        completion(context.isPreview ? .placeholder : StarcatWidgetSnapshotLoader.load())
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<StarcatWidgetEntry>) -> Void
    ) {
        let entry = StarcatWidgetSnapshotLoader.load()
        completion(
            Timeline(
                entries: [entry],
                policy: .after(
                    StarcatWidgetSnapshotLoader.nextRefresh(
                        after: entry.date,
                        isReady: entry.snapshot != nil,
                        kind: .standard
                    )
                )
            )
        )
    }
}
