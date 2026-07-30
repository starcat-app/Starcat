//
//  StarcatRediscoveryWidget.swift
//  StarcatWidgets
//
//  每天稳定展示一个长期未关注仓库的“今日重逢”Widget。
//

import SwiftUI
import WidgetKit

struct StarcatRediscoveryWidget: Widget {
    private let kind = "com.starcat.widget.rediscovery"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StarcatRediscoveryProvider()) { entry in
            StarcatRediscoveryWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color.clear
                }
        }
        .configurationDisplayName("widget.rediscovery.displayName")
        .description("widget.rediscovery.description")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct StarcatRediscoveryProvider: TimelineProvider {
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
                        kind: .rediscovery
                    )
                )
            )
        )
    }
}

struct StarcatRediscoveryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StarcatWidgetEntry

    var body: some View {
        if let emptyView = entry.content.emptyView {
            emptyView
        } else if let repository = entry.snapshot?.rediscoveryRepository {
            if family == .systemSmall {
                smallContent(repository: repository)
            } else {
                mediumContent(repository: repository)
            }
        } else {
            StarcatWidgetEmptyView(
                symbol: "sparkles",
                titleKey: "widget.rediscovery.empty.title",
                subtitleKey: "widget.rediscovery.empty.subtitle"
            )
        }
    }

    private func smallContent(repository: WidgetRepository) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                StarcatWidgetAvatar(fileName: repository.avatarFileName, size: 42)
                Spacer()
                if entry.isStale {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("widget.common.stale"))
                }
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text("widget.rediscovery.title")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(verbatim: "\(repository.owner)/\(repository.name)")
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
            if let language = repository.language {
                Text(verbatim: language)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .widgetURL(repository.openURL)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(repository.owner)/\(repository.name)"))
        .accessibilityHint(Text("widget.common.openRepository"))
    }

    private func mediumContent(repository: WidgetRepository) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            StarcatWidgetHeader(
                "widget.rediscovery.title",
                systemImage: "sparkles",
                isStale: entry.isStale
            )
            .padding(.bottom, 10)

            HStack(spacing: 12) {
                StarcatWidgetAvatar(fileName: repository.avatarFileName, size: 52)

                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "\(repository.owner)/\(repository.name)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let description = repository.description {
                        Text(verbatim: description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 8) {
                        if let language = repository.language {
                            Label {
                                Text(verbatim: language)
                            } icon: {
                                Image(systemName: "chevron.left.forwardslash.chevron.right")
                            }
                        }
                        Label {
                            Text(repository.starsCount, format: .number)
                        } icon: {
                            Image(systemName: "star.fill")
                        }
                        // Medium 宽度有限，只展示最高优先级标签，避免元信息挤压仓库名。
                        ForEach(repository.tags.prefix(1), id: \.self) { tag in
                            Text(verbatim: tag)
                                .lineLimit(1)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(repository.openURL)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(repository.owner)/\(repository.name)"))
        .accessibilityHint(Text("widget.common.openRepository"))
    }
}
