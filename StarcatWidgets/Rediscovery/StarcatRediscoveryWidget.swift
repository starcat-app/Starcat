//
//  StarcatRediscoveryWidget.swift
//  StarcatWidgets
//
//  每天稳定展示一个长期未关注仓库的“仓库回顾”Widget。
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
                symbol: "clock.arrow.circlepath",
                titleKey: "widget.rediscovery.empty.title",
                subtitleKey: "widget.rediscovery.empty.subtitle"
            )
        }
    }

    private func smallContent(repository: WidgetRepository) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                StarcatWidgetAvatar(fileName: repository.avatarFileName, size: 42)
                Spacer()
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                if entry.isStale {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("widget.common.stale"))
                }
            }

            Spacer(minLength: 0)

            Text(verbatim: repository.owner)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(verbatim: repository.name)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            HStack(spacing: 8) {
                if let language = repository.language {
                    Label {
                        Text(verbatim: language)
                    } icon: {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                    }
                    .lineLimit(1)
                }
                Label {
                    Text(
                        repository.starsCount,
                        format: .number.notation(.compactName)
                    )
                } icon: {
                    Image(systemName: "star.fill")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .widgetURL(repository.openURL)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(repository.rediscoveryAccessibilityLabel)
        .accessibilityHint(Text("widget.common.openRepository"))
    }

    private func mediumContent(repository: WidgetRepository) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("widget.rediscovery.title")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if entry.isStale {
                        Image(systemName: "clock.badge.exclamationmark")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("widget.common.stale"))
                    }
                }
                .font(.caption.weight(.semibold))

                Spacer(minLength: 4)
                StarcatWidgetAvatar(fileName: repository.avatarFileName, size: 42)
                Text(verbatim: repository.owner)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(verbatim: repository.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider().opacity(0.35)

            VStack(alignment: .leading, spacing: 6) {
                if let description = repository.description {
                    Text(verbatim: description)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                }

                Spacer(minLength: 4)

                HStack(spacing: 10) {
                    if let language = repository.language {
                        Label {
                            Text(verbatim: language)
                        } icon: {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                        }
                        .lineLimit(1)
                    }

                    Label {
                        Text(repository.starsCount, format: .number.notation(.compactName))
                    } icon: {
                        Image(systemName: "star.fill")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    ForEach(repository.tags.prefix(3), id: \.self) { tag in
                        Text(verbatim: "#\(tag)")
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(repository.openURL)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(repository.rediscoveryAccessibilityLabel)
        .accessibilityHint(Text("widget.common.openRepository"))
    }
}

private extension WidgetRepository {
    var rediscoveryAccessibilityLabel: Text {
        Text("widget.rediscovery.title")
            + Text(verbatim: ", \(owner)/\(name)")
    }
}
