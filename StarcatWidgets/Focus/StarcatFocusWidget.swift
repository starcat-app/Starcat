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
                symbol: "scope",
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
            repositoryDashboard(limit: 3, usesSplitLayout: true)
        default:
            repositoryDashboard(limit: 6, usesSplitLayout: false)
        }
    }

    private func smallContent(repository: WidgetRepository) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                StarcatWidgetAvatar(fileName: repository.avatarFileName, size: 42)
                Spacer()
                if entry.base.isStale {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("widget.common.stale"))
                }
                StarcatFocusStatusLabel(source: repository.focusSource)
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
                    Text(repository.starsCount, format: .number.notation(.compactName))
                } icon: {
                    Image(systemName: "star.fill")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .widgetURL(repository.openURL)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(repository.focusAccessibilityLabel)
        .accessibilityHint(Text("widget.common.openRepository"))
    }

    @ViewBuilder
    private func repositoryDashboard(
        limit: Int,
        usesSplitLayout: Bool
    ) -> some View {
        let repositories = Array(entry.repositories.prefix(limit))
        let secondaryRepositories = Array(repositories.dropFirst())

        if let featuredRepository = repositories.first {
            VStack(alignment: .leading, spacing: 0) {
                StarcatWidgetHeader(
                    "widget.focus.title",
                    systemImage: "scope",
                    isStale: entry.base.isStale
                )
                .padding(.bottom, usesSplitLayout ? 8 : 5)

                if usesSplitLayout {
                    HStack(alignment: .top, spacing: 14) {
                        Link(destination: featuredRepository.openURL) {
                            StarcatFocusFeaturedRepository(
                                repository: featuredRepository,
                                isExpanded: false
                            )
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if !secondaryRepositories.isEmpty {
                            Divider().opacity(0.35)

                            VStack(alignment: .leading, spacing: 0) {
                                secondaryRepositoryList(secondaryRepositories)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    Link(destination: featuredRepository.openURL) {
                        StarcatFocusFeaturedRepository(
                            repository: featuredRepository,
                            isExpanded: true
                        )
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()

                    if !secondaryRepositories.isEmpty {
                        Divider().opacity(0.35)
                        secondaryRepositoryList(secondaryRepositories)
                    }
                }
            }
        }
    }

    private func secondaryRepositoryList(
        _ repositories: [WidgetRepository]
    ) -> some View {
        // Gallery 占位数据会复用同一个仓库填满列表，因此视图身份必须使用当前位置；
        // 若直接使用 repository.id，重复 ID 会让 SwiftUI 的 diff 结果变得不确定。
        ForEach(Array(repositories.enumerated()), id: \.offset) { index, repository in
            Link(destination: repository.openURL) {
                StarcatFocusRepositoryRow(repository: repository)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            if index < repositories.count - 1 {
                Divider().opacity(0.35)
            }
        }
    }
}

private struct StarcatFocusRepositoryRow: View {
    let repository: WidgetRepository

    var body: some View {
        HStack(spacing: 8) {
            StarcatWidgetAvatar(fileName: repository.avatarFileName, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(repository.owner)/\(repository.name)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let language = repository.language {
                        Text(verbatim: language)
                            .lineLimit(1)
                    }
                    StarcatFocusStatusLabel(source: repository.focusSource)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(repository.focusAccessibilityLabel)
        .accessibilityHint(Text("widget.common.openRepository"))
    }

}

/// Focus 只展示可操作的仓库工作状态，不重复解释仓库为何进入候选列表。
///
/// `.pinned` 仍参与主应用快照排序，但不再渲染成文字或图标，避免被误解为
/// Widget 内的置顶操作；`.using` 是用户主动维护的工作状态，因此继续展示。
struct StarcatFocusStatusLabel: View {
    let source: WidgetFocusSource?

    @ViewBuilder
    var body: some View {
        switch source {
        case .pinned:
            EmptyView()
        case .using:
            Label("widget.focus.using", systemImage: "hammer.fill")
                .lineLimit(1)
        case nil:
            EmptyView()
        }
    }
}

extension WidgetRepository {
    /// 显式 label 会覆盖 `.combine` 的自动结果，因此只补充仍然可见的“使用中”状态。
    var focusAccessibilityLabel: Text {
        let repository = Text(verbatim: "\(owner)/\(name)")
        switch focusSource {
        case .pinned:
            return repository
        case .using:
            return repository + Text(verbatim: ", ") + Text("widget.focus.using")
        case nil:
            return repository
        }
    }
}
