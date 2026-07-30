//
//  StarcatFocusWidget.swift
//  StarcatWidgets
//
//  展示置顶或正在使用仓库的可配置 Focus Widget。
//

import AppIntents
import SwiftUI
import WidgetKit

struct StarcatFocusWidget: Widget {
    private let kind = "com.starcat.widget.focus"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: FocusWidgetConfigurationIntent.self,
            provider: StarcatFocusProvider()
        ) { entry in
            StarcatFocusWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color.clear
                }
        }
        .configurationDisplayName("widget.focus.displayName")
        .description("widget.focus.description")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct StarcatFocusEntry: TimelineEntry {
    let date: Date
    let base: StarcatWidgetEntry
    let repositories: [WidgetRepository]
}

struct StarcatFocusProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> StarcatFocusEntry {
        makeEntry(base: .placeholder, configuration: FocusWidgetConfigurationIntent())
    }

    func snapshot(
        for configuration: FocusWidgetConfigurationIntent,
        in context: Context
    ) async -> StarcatFocusEntry {
        makeEntry(base: StarcatWidgetSnapshotLoader.load(), configuration: configuration)
    }

    func timeline(
        for configuration: FocusWidgetConfigurationIntent,
        in context: Context
    ) async -> Timeline<StarcatFocusEntry> {
        let base = StarcatWidgetSnapshotLoader.load()
        let entry = makeEntry(base: base, configuration: configuration)
        return Timeline(
            entries: [entry],
            policy: .after(
                StarcatWidgetSnapshotLoader.nextRefresh(
                    after: entry.date,
                    isReady: entry.base.snapshot != nil,
                    kind: .standard
                )
            )
        )
    }

    private func makeEntry(
        base: StarcatWidgetEntry,
        configuration: FocusWidgetConfigurationIntent
    ) -> StarcatFocusEntry {
        var repositories = base.snapshot?.focusRepositories ?? []
        if let selectedID = configuration.repository?.repositoryID,
           let selectedIndex = repositories.firstIndex(where: { $0.id == selectedID }) {
            let selected = repositories.remove(at: selectedIndex)
            repositories.insert(selected, at: 0)
        }
        return StarcatFocusEntry(
            date: base.date,
            base: base,
            repositories: Array(repositories.prefix(6))
        )
    }
}

struct StarcatFocusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StarcatFocusEntry

    var body: some View {
        if let emptyView = entry.base.content.emptyView {
            emptyView
        } else if entry.repositories.isEmpty {
            StarcatWidgetEmptyView(
                symbol: "pin",
                titleKey: "widget.focus.empty.title",
                subtitleKey: "widget.focus.empty.subtitle"
            )
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemSmall:
            smallContent(repository: entry.repositories[0])
        case .systemMedium:
            repositoryList(limit: 3, showsDescription: false, usesCompactRows: false)
        default:
            repositoryList(limit: 6, showsDescription: true, usesCompactRows: true)
        }
    }

    private func smallContent(repository: WidgetRepository) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StarcatWidgetAvatar(fileName: repository.avatarFileName, size: 38)
                Spacer()
                if entry.base.isStale {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("widget.common.stale"))
                }
                StarcatFocusSourceLabel(source: repository.focusSource)
            }
            Spacer(minLength: 0)
            Text(verbatim: repository.owner)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(verbatim: repository.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
            if let language = repository.language {
                Label {
                    Text(verbatim: language)
                } icon: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .widgetURL(repository.openURL)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(repository.focusAccessibilityLabel)
        .accessibilityHint(Text("widget.common.openRepository"))
    }

    private func repositoryList(
        limit: Int,
        showsDescription: Bool,
        usesCompactRows: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            StarcatWidgetHeader(
                "widget.focus.title",
                systemImage: "pin.fill",
                isStale: entry.base.isStale
            )
            .padding(.bottom, usesCompactRows ? 4 : 6)

            // Gallery 占位数据会复用同一个仓库填满列表；使用当前 Timeline 内唯一的
            // 行位置作为视图身份，避免重复 repo ID 触发 SwiftUI 未定义 diff 行为。
            ForEach(Array(entry.repositories.prefix(limit).enumerated()), id: \.offset) {
                index,
                repository in
                Link(destination: repository.openURL) {
                    StarcatFocusRepositoryRow(
                        repository: repository,
                        showsDescription: showsDescription,
                        usesCompactLayout: usesCompactRows
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                if index < min(limit, entry.repositories.count) - 1 {
                    Divider().opacity(0.35)
                }
            }
        }
    }
}

private struct StarcatFocusRepositoryRow: View {
    let repository: WidgetRepository
    let showsDescription: Bool
    let usesCompactLayout: Bool

    var body: some View {
        HStack(spacing: usesCompactLayout ? 7 : 8) {
            StarcatWidgetAvatar(
                fileName: repository.avatarFileName,
                size: usesCompactLayout ? 28 : 30
            )
            VStack(alignment: .leading, spacing: usesCompactLayout ? 1 : 2) {
                Text(verbatim: "\(repository.owner)/\(repository.name)")
                    .font(
                        usesCompactLayout
                            ? .caption.weight(.semibold)
                            : .subheadline.weight(.semibold)
                    )
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if showsDescription, let description = repository.description {
                    Text(verbatim: description)
                        .font(usesCompactLayout ? .caption2 : .caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let language = repository.language {
                        Text(verbatim: language)
                            .lineLimit(1)
                    }
                    StarcatFocusSourceLabel(source: repository.focusSource)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, usesCompactLayout ? 2 : 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(repository.focusAccessibilityLabel)
        .accessibilityHint(Text("widget.common.openRepository"))
    }

}

private struct StarcatFocusSourceLabel: View {
    let source: WidgetFocusSource?

    @ViewBuilder
    var body: some View {
        switch source {
        case .pinned:
            Label("widget.focus.pinned", systemImage: "pin.fill")
                .lineLimit(1)
        case .using:
            Label("widget.focus.using", systemImage: "hammer.fill")
                .lineLimit(1)
        case nil:
            EmptyView()
        }
    }
}

private extension WidgetRepository {
    /// 显式 label 会覆盖 `.combine` 的自动结果，因此在这里把视觉来源一并读出。
    var focusAccessibilityLabel: Text {
        let repository = Text(verbatim: "\(owner)/\(name)")
        switch focusSource {
        case .pinned:
            return repository + Text(verbatim: ", ") + Text("widget.focus.pinned")
        case .using:
            return repository + Text(verbatim: ", ") + Text("widget.focus.using")
        case nil:
            return repository
        }
    }
}
