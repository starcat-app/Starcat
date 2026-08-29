//
//  StarcatReleaseWatchWidget.swift
//  StarcatWidgets
//
//  展示已订阅公开仓库未读 Release 的只读 Widget。
//

import SwiftUI
import WidgetKit

struct StarcatReleaseWatchWidget: Widget {
    private let kind = "com.starcat.widget.release-watch"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StarcatReleaseWatchProvider()) { entry in
            StarcatReleaseWatchWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color.clear
                }
        }
        .configurationDisplayName("widget.releaseWatch.displayName")
        .description("widget.releaseWatch.description")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct StarcatReleaseWatchProvider: TimelineProvider {
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

struct StarcatReleaseWatchWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StarcatWidgetEntry

    private var timelineURL: URL {
        WidgetAppDeepLink(destination: .releaseTimeline).url
    }

    var body: some View {
        if let emptyView = entry.content.emptyView {
            emptyView
        } else if let snapshot = entry.snapshot, !snapshot.unreadReleases.isEmpty {
            if family == .systemSmall {
                releaseSummary(snapshot: snapshot)
            } else {
                releaseList(snapshot: snapshot)
            }
        } else {
            StarcatWidgetEmptyView(
                symbol: "checkmark.circle",
                titleKey: "widget.releaseWatch.empty.title",
                subtitleKey: "widget.releaseWatch.empty.subtitle",
                openURL: timelineURL,
                accessibilityHintKey: "widget.releaseWatch.openTimeline"
            )
        }
    }

    /// Small 采用单 KPI 卡片：图标建立语义，大数字优先表达需要处理的 Release 数量。
    private func releaseSummary(snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "shippingbox.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Spacer()
                if entry.isStale {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("widget.common.stale"))
                }
            }

            Spacer(minLength: 8)

            Text(verbatim: "\(snapshot.unreadReleaseCount)")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
                .minimumScaleFactor(0.75)
                .lineLimit(1)
            Text("widget.releaseWatch.unreadLabel")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .widgetURL(timelineURL)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("widget.releaseWatch.unread \(snapshot.unreadReleaseCount)"))
        .accessibilityHint(Text("widget.releaseWatch.openTimeline"))
    }

    private func releaseList(snapshot: WidgetSnapshot) -> some View {
        let limit = family == .systemLarge ? 6 : 3
        return VStack(alignment: .leading, spacing: 0) {
            StarcatWidgetHeader(
                "widget.releaseWatch.title",
                systemImage: "shippingbox",
                isStale: entry.isStale
            ) {
                Text("widget.releaseWatch.unreadShort \(snapshot.unreadReleaseCount)")
                    .lineLimit(1)
                    .accessibilityLabel(
                        Text("widget.releaseWatch.unread \(snapshot.unreadReleaseCount)")
                    )
            }
            .padding(.bottom, 6)

            ForEach(Array(snapshot.unreadReleases.prefix(limit).enumerated()), id: \.element.id) {
                index,
                release in
                Link(destination: release.openURL) {
                    StarcatReleaseWatchRow(release: release)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                if index < min(limit, snapshot.unreadReleases.count) - 1 {
                    Divider().opacity(0.35)
                }
            }
        }
    }
}

private struct StarcatReleaseWatchRow: View {
    let release: WidgetRelease

    var body: some View {
        HStack(spacing: 8) {
            StarcatWidgetAvatar(fileName: release.avatarFileName)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(release.owner)/\(release.repositoryName)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(verbatim: release.tagName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if release.isPrerelease {
                        Text("widget.releaseWatch.prerelease")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 4)
            if let publishedAt = release.publishedAt {
                // RelativeFormatStyle 只保留主要时间单位，避免“7 小时 47 分钟”挤压 tag。
                Text(
                    publishedAt,
                    format: .relative(presentation: .numeric, unitsStyle: .abbreviated)
                )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text(verbatim: "\(release.owner)/\(release.repositoryName) \(release.tagName)")
        )
        .accessibilityHint(Text("widget.releaseWatch.openRelease"))
    }
}
