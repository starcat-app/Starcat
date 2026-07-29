//
//  StarcatFocusWidget.swift
//  StarcatWidgets
//
//  展示置顶或正在使用仓库的可配置 Focus Widget。
//

import AppIntents
import SwiftUI
import WidgetKit

struct FocusWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "widget.focus.configuration.title"
    static let description = IntentDescription("widget.focus.configuration.description")

    @Parameter(title: "widget.focus.configuration.repository")
    var repository: WidgetRepositoryEntity?

    init() {}
}

struct WidgetRepositoryEntity: AppEntity, Identifiable, Hashable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "widget.focus.entity.type"
    )
    static let defaultQuery = WidgetRepositoryEntityQuery()

    let id: String
    let repositoryID: Int64
    let owner: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(owner)/\(name)")
    }
}

struct WidgetRepositoryEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetRepositoryEntity] {
        let identifierSet = Set(identifiers)
        return Self.availableEntities().filter { identifierSet.contains($0.id) }
    }

    func suggestedEntities() async throws -> [WidgetRepositoryEntity] {
        Self.availableEntities()
    }

    private static func availableEntities() -> [WidgetRepositoryEntity] {
        guard let snapshot = StarcatWidgetSnapshotLoader.load().snapshot else { return [] }
        var seen = Set<Int64>()
        return snapshot.focusRepositories.compactMap { repository in
            guard seen.insert(repository.id).inserted else { return nil }
            return WidgetRepositoryEntity(
                id: String(repository.id),
                repositoryID: repository.id,
                owner: repository.owner,
                name: repository.name
            )
        }
    }
}

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
            repositoryList(limit: 3, showsDescription: false)
        default:
            repositoryList(limit: 6, showsDescription: true)
        }
    }

    private func smallContent(repository: WidgetRepository) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StarcatWidgetAvatar(fileName: repository.avatarFileName, size: 38)
                Spacer()
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
        .accessibilityLabel(Text(verbatim: "\(repository.owner)/\(repository.name)"))
    }

    private func repositoryList(limit: Int, showsDescription: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("widget.focus.title", systemImage: "pin.fill")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                if entry.base.isStale {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("widget.common.stale"))
                }
            }
            .padding(.bottom, 6)

            ForEach(Array(entry.repositories.prefix(limit).enumerated()), id: \.element.id) {
                index,
                repository in
                Link(destination: repository.openURL) {
                    StarcatFocusRepositoryRow(
                        repository: repository,
                        showsDescription: showsDescription
                    )
                }
                .buttonStyle(.plain)
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

    var body: some View {
        HStack(spacing: 8) {
            StarcatWidgetAvatar(fileName: repository.avatarFileName)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(repository.owner)/\(repository.name)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if showsDescription, let description = repository.description {
                    Text(verbatim: description)
                        .font(.caption)
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
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(repository.owner)/\(repository.name)"))
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
