//
//  AwesomeView.swift
//  Starcat
//
//  探索 → Awesome 中栏：全部/单来源、章节筛选、搜索、排序和统一 Repo 行。
//
//  README 章节只在中栏筛选，不展开到 Sidebar。全部来源按 Repository 已聚合的 GitHub ID
//  去重结果展示；单来源沿 README 原始顺序分组，来源描述只作为 metadata，不覆盖官方描述。
//

import SwiftUI

struct AwesomeView: View {
    let store: AwesomeStore
    let onRepoCountChange: (Int) -> Void

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @State private var searchText = ""
    @State private var selectedSection: String?
    @State private var sort: AwesomeSortOption = .original

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            filterBar
            Divider()
            errorBanner
            content
        }
        .task(id: authSession.state.isAuthenticated) {
            guard authSession.state.isAuthenticated else {
                onRepoCountChange(0)
                return
            }
            await store.loadAwesome()
            reportCount()
        }
        .onChange(of: store.selectedSourceID) { _, _ in
            selectedSection = nil
            sort = .original
            reportCount()
        }
        .onChange(of: filteredRepositories.count) { _, _ in reportCount() }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("awesome.search.placeholder", text: $searchText)
                .textFieldStyle(.plain)

            if store.selectedSourceID != nil {
                Picker("awesome.section.title", selection: $selectedSection) {
                    Text("awesome.section.all").tag(String?.none)
                    ForEach(availableSections, id: \.self) { section in
                        Text(section).tag(String?.some(section))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 180)
            }

            Picker("awesome.sort.title", selection: $sort) {
                ForEach(AwesomeSortOption.allCases) { option in
                    Text(option.titleKey).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 130)
        }
        .padding(.horizontal, ManageListFilterBarMetrics.horizontalPadding)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = store.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ManageListFilterBarMetrics.horizontalPadding)
                .padding(.vertical, 6)
                .background(.bar)
        } else if !store.sourceRefreshErrors.isEmpty {
            Text(String(format: String.l10n("awesome.error.partialRefreshFormat"), store.sourceRefreshErrors.count))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ManageListFilterBarMetrics.horizontalPadding)
                .padding(.vertical, 6)
                .background(.bar)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !authSession.state.isAuthenticated {
            ContentUnavailableView {
                Label("sidebar.loginPrompt", systemImage: "person.crop.circle.badge.exclamationmark")
            }
        } else if store.isLoading, store.repositories.isEmpty {
            RepoSkeletonListView(rowCount: 10)
        } else if store.enabledSources.isEmpty {
            ContentUnavailableView {
                Label("awesome.empty.noSources.title", systemImage: "sparkles.rectangle.stack")
            } description: {
                Text("awesome.empty.noSources.subtitle")
            } actions: {
                Button("awesome.sources.manage") {
                    Task { await store.presentSourceManager() }
                }
            }
        } else if filteredRepositories.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            repositoryList
        }
    }

    private var repositoryList: some View {
        List {
            ForEach(sectionGroups) { group in
                Section(group.title) {
                    ForEach(group.repositories) { repo in
                        repositoryRow(repo)
                    }
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .scrollContentBackground(.hidden)
        .refreshable { await store.refresh() }
    }

    private func repositoryRow(_ repo: AwesomeRepositoryItem) -> some View {
        Button {
            store.selectedRepositoryID = repo.id
        } label: {
            UnifiedRepoRow(
                card: repo.discoveryDTO.asCardData(
                    registry: dependencies.starredRegistry,
                    footerMetadata: footerMetadata(for: repo),
                    openSSFScore: dependencies.openSSFScoreStore.badge(for: repo.id)
                ),
                isSelected: store.selectedRepositoryID == repo.id,
                showStarredCheckmark: true
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func footerMetadata(for repo: AwesomeRepositoryItem) -> RepoCardInlineMetadata? {
        if store.selectedSourceID == nil, repo.evidence.count > 1 {
            return RepoCardInlineMetadata(
                systemImage: "square.stack.3d.up",
                text: String(format: String.l10n("awesome.repo.sourceCountFormat"), repo.evidence.count)
            )
        }
        guard let evidence = repo.evidence.first else { return nil }
        let text = evidence.entryDescription ?? evidence.sectionPath.last
        return text.map { RepoCardInlineMetadata(systemImage: "text.quote", text: $0) }
    }

    private var availableSections: [String] {
        var seen: Set<String> = []
        return store.repositories.compactMap { repo in
            let section = repo.evidence.first?.sectionPath.joined(separator: " / ")
            guard let section, !section.isEmpty, seen.insert(section).inserted else { return nil }
            return section
        }
    }

    private var filteredRepositories: [AwesomeRepositoryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = store.repositories.filter { repo in
            let matchesSection = selectedSection == nil || repo.evidence.contains {
                $0.sectionPath.joined(separator: " / ") == selectedSection
            }
            guard matchesSection else { return false }
            guard !query.isEmpty else { return true }
            let fields: [String?] = [repo.fullName, repo.description]
                + repo.evidence.flatMap { [$0.entryTitle, $0.entryDescription, $0.source.displayName] }
            return fields.compactMap { $0?.lowercased() }.contains { $0.contains(query) }
        }
        switch sort {
        case .original:
            return filtered
        case .stars:
            return filtered.sorted { $0.stars == $1.stars ? $0.id < $1.id : $0.stars > $1.stars }
        case .updated:
            return filtered.sorted {
                if $0.updatedAt != $1.updatedAt {
                    return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
                }
                return $0.id < $1.id
            }
        case .name:
            return filtered.sorted { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
        }
    }

    private var sectionGroups: [AwesomeSectionGroup] {
        guard store.selectedSourceID != nil, sort == .original, selectedSection == nil else {
            return [AwesomeSectionGroup(title: String.l10n("awesome.section.results"), repositories: filteredRepositories)]
        }
        var order: [String] = []
        let grouped = Dictionary(grouping: filteredRepositories) { repo in
            repo.evidence.first?.sectionPath.joined(separator: " / ") ?? String.l10n("awesome.section.other")
        }
        for repo in filteredRepositories {
            let title = repo.evidence.first?.sectionPath.joined(separator: " / ") ?? String.l10n("awesome.section.other")
            if !order.contains(title) { order.append(title) }
        }
        return order.map { AwesomeSectionGroup(title: $0, repositories: grouped[$0] ?? []) }
    }

    private func reportCount() {
        onRepoCountChange(filteredRepositories.count)
    }
}

private enum AwesomeSortOption: String, CaseIterable, Identifiable {
    case original
    case stars
    case updated
    case name

    var id: String { rawValue }
    var titleKey: LocalizedStringKey {
        switch self {
        case .original: return "awesome.sort.original"
        case .stars: return "awesome.sort.stars"
        case .updated: return "awesome.sort.updated"
        case .name: return "awesome.sort.name"
        }
    }
}

private struct AwesomeSectionGroup: Identifiable {
    let title: String
    let repositories: [AwesomeRepositoryItem]
    var id: String { title }
}
