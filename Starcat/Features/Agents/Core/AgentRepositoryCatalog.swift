//
//  AgentRepositoryCatalog.swift
//  Starcat
//
//  Agent 可读取仓库的统一目录。Star、知识库、Weekly、Trending、Discovery 是并列
//  来源，不是互相替代的准入条件；目录按 GitHub repo ID 合并这些本地事实。
//

import Foundation
import GRDB
import SwiftUI

/// Agent 仓库目录中的来源维度。
enum AgentRepositorySource: String, CaseIterable, Codable, Hashable, Sendable {
    case local
    case starred
    case knowledge
    case weekly
    case trending
    case discovery

    var title: LocalizedStringKey {
        switch self {
        case .local: return "agent.workspace.repositoryPicker.source.local"
        case .starred: return "agent.workspace.repositoryPicker.source.starred"
        case .knowledge: return "agent.workspace.repositoryPicker.source.knowledge"
        case .weekly: return "agent.workspace.repositoryPicker.source.weekly"
        case .trending: return "agent.workspace.repositoryPicker.source.trending"
        case .discovery: return "agent.workspace.repositoryPicker.source.discovery"
        }
    }

    var systemImage: String {
        switch self {
        case .local: return "internaldrive"
        case .starred: return "star.fill"
        case .knowledge: return "books.vertical"
        case .weekly: return "newspaper"
        case .trending: return "flame"
        case .discovery: return "sparkles"
        }
    }
}

/// 目录中的统一候选。运行时只冻结 `snapshot`；其余字段只服务选择器筛选与排序。
struct AgentRepositoryCandidate: Identifiable, Hashable, Sendable {
    var snapshot: AgentRepoSnapshot
    var ownerAvatar: String?
    var sources: Set<AgentRepositorySource>
    var status: RepoStatus
    var isArchived: Bool
    var isFork: Bool
    var pushedAt: String?
    var createdAt: String?
    var updatedAt: String?
    var libraryUpdatedAt: String?
    /// 仅记录 Weekly Feed 的事件时间；其它缓存的 `cached_at` 不得污染周报时间窗。
    var firstObservedAt: String?
    var latestObservedAt: String?
    var normalizedSearchText: String

    var id: Int64 { snapshot.id }
    var owner: String { snapshot.owner }
    var name: String { snapshot.name }
    var fullName: String { snapshot.fullName }
    var language: String? { snapshot.language }
    var starsCount: Int { snapshot.starsCount }

    var mentionCandidate: RAGMentionCandidate {
        RAGMentionCandidate(agentCandidate: self)
    }
}

/// Agent 目录读取协议。读取只发生在本地 SQLite，不触发网络或写入用户数据。
protocol AgentRepositoryCatalogProviding: Sendable {
    func candidates() async throws -> [AgentRepositoryCandidate]
}

/// 基于 Starcat 已有缓存表构建 Agent 仓库全集。
actor GRDBAgentRepositoryCatalog: AgentRepositoryCatalogProviding {
    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    func candidates() async throws -> [AgentRepositoryCandidate] {
        try await database.writer.read { db in
            let repos = try Repo.fetchAll(db)
            let notes = try RepoNote.fetchAll(db)
            let weekly = try WeeklyBulkRepoRecord.fetchAll(db)
            let trending = try TrendingRepoRecord.fetchAll(db)
            let discovery = try DiscoveryBulkRepoRecord.fetchAll(db)
            let notesByRepoID = Dictionary(uniqueKeysWithValues: notes.map { ($0.repoId, $0) })

            var merged: [Int64: AgentRepositoryCandidate] = [:]

            // `repos` 保存用户侧 Star / 知识库事实，必须先成为合并基线；公共缓存只能
            // 补充来源和较新的公开元数据，不能覆盖用户关系。
            for repo in repos where repo.id > 0 {
                let note = notesByRepoID[repo.id]
                var sources: Set<AgentRepositorySource> = [.local]
                if repo.isStarred { sources.insert(.starred) }
                if LibraryState.parse(note?.libraryState) == .inLibrary { sources.insert(.knowledge) }
                merged[repo.id] = Self.candidate(repo: repo, note: note, sources: sources)
            }

            for record in weekly where record.ghRepoId > 0 {
                guard let item = record.toDomain() else { continue }
                Self.merge(
                    Self.candidate(weekly: item),
                    into: &merged
                )
            }

            // Trending 同一 repo 可能出现在多个 period / language bucket；按 ID 合并来源，
            // 并用 cached_at 较新的那条公开快照补足目录字段。
            for record in trending {
                guard let repoID = record.ghRepoId, repoID > 0 else { continue }
                Self.merge(Self.candidate(trending: record, repoID: repoID), into: &merged)
            }

            for record in discovery where record.repoID > 0 {
                Self.merge(Self.candidate(discovery: record), into: &merged)
            }

            return Array(merged.values)
        }
    }

    private static func candidate(
        repo: Repo,
        note: RepoNote?,
        sources: Set<AgentRepositorySource>
    ) -> AgentRepositoryCandidate {
        let snapshot = AgentRepoSnapshot(
            id: repo.id,
            owner: repo.owner,
            name: repo.name,
            fullName: repo.fullName,
            description: repo.description,
            language: repo.language,
            starsCount: repo.starsCount,
            topics: repo.topicsArray,
            isPrivate: repo.isPrivate,
            isStarred: repo.isStarred,
            starredAt: repo.starredAt,
            htmlUrl: repo.htmlUrl,
            sourceIDs: sources.map(\.rawValue).sorted(),
            firstObservedAt: nil,
            latestObservedAt: repo.cachedAt
        )
        return AgentRepositoryCandidate(
            snapshot: snapshot,
            ownerAvatar: repo.ownerAvatar,
            sources: sources,
            status: note.map { RepoStatus.parse($0.status) } ?? .unread,
            isArchived: repo.isArchived,
            isFork: repo.isFork,
            pushedAt: repo.pushedAt,
            createdAt: repo.createdAt,
            updatedAt: repo.updatedAt,
            libraryUpdatedAt: note?.libraryUpdatedAt,
            firstObservedAt: nil,
            latestObservedAt: nil,
            normalizedSearchText: normalizedSearchText(
                fullName: repo.fullName,
                description: repo.description,
                language: repo.language,
                topics: repo.topicsArray,
                status: note?.status
            )
        )
    }

    private static func candidate(weekly item: WeeklyFeedItem) -> AgentRepositoryCandidate {
        let sourceIDs = Set(item.sourceTypes.map(\.rawValue) + [AgentRepositorySource.weekly.rawValue]).sorted()
        let snapshot = AgentRepoSnapshot(
            id: item.id,
            owner: item.owner,
            name: item.name,
            fullName: item.fullName,
            description: item.description,
            language: item.language,
            starsCount: item.stars,
            topics: item.card.topics,
            isPrivate: item.card.isPrivate,
            isStarred: false,
            starredAt: nil,
            htmlUrl: item.url.absoluteString,
            sourceIDs: sourceIDs,
            firstObservedAt: item.firstEventAt,
            latestObservedAt: item.latestEventAt
        )
        return AgentRepositoryCandidate(
            snapshot: snapshot,
            ownerAvatar: item.card.ownerAvatar?.absoluteString,
            sources: [.weekly],
            status: .unread,
            isArchived: item.card.isArchived,
            isFork: item.card.isFork,
            pushedAt: item.card.pushedAt,
            createdAt: item.card.createdAt,
            updatedAt: item.card.updatedAt,
            libraryUpdatedAt: nil,
            firstObservedAt: item.firstEventAt,
            latestObservedAt: item.latestEventAt,
            normalizedSearchText: normalizedSearchText(
                fullName: item.fullName,
                description: item.description,
                language: item.language,
                topics: item.card.topics,
                status: nil
            )
        )
    }

    private static func candidate(
        trending record: TrendingRepoRecord,
        repoID: Int64
    ) -> AgentRepositoryCandidate {
        let topics = decodeTopics(record.topics)
        let snapshot = AgentRepoSnapshot(
            id: repoID,
            owner: record.owner,
            name: record.name,
            fullName: record.fullName,
            description: record.description,
            language: record.language,
            starsCount: record.starsCount,
            topics: topics,
            isPrivate: record.isPrivate ?? false,
            isStarred: false,
            starredAt: nil,
            htmlUrl: GitHubURLs.repo(fullName: record.fullName).absoluteString,
            sourceIDs: [AgentRepositorySource.trending.rawValue],
            firstObservedAt: nil,
            latestObservedAt: record.cachedAt
        )
        return AgentRepositoryCandidate(
            snapshot: snapshot,
            ownerAvatar: record.ownerAvatar,
            sources: [.trending],
            status: .unread,
            isArchived: record.isArchived ?? false,
            isFork: record.isFork ?? false,
            pushedAt: record.pushedAt,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            libraryUpdatedAt: nil,
            firstObservedAt: nil,
            // Weekly 时间窗只认 Weekly 事件时间；Trending 缓存刷新不能把旧周报项目
            // 伪装成“最近 7 天观察到”。
            latestObservedAt: nil,
            normalizedSearchText: normalizedSearchText(
                fullName: record.fullName,
                description: record.description,
                language: record.language,
                topics: topics,
                status: nil
            )
        )
    }

    private static func candidate(discovery record: DiscoveryBulkRepoRecord) -> AgentRepositoryCandidate {
        let topics = decodeTopics(record.topicsJSON)
        let snapshot = AgentRepoSnapshot(
            id: record.repoID,
            owner: record.owner,
            name: record.name,
            fullName: record.fullName,
            description: record.description,
            language: record.language,
            starsCount: record.stars,
            topics: topics,
            isPrivate: false,
            isStarred: false,
            starredAt: nil,
            htmlUrl: GitHubURLs.repo(fullName: record.fullName).absoluteString,
            sourceIDs: [AgentRepositorySource.discovery.rawValue],
            firstObservedAt: nil,
            latestObservedAt: record.cachedAt
        )
        return AgentRepositoryCandidate(
            snapshot: snapshot,
            ownerAvatar: record.ownerAvatar,
            sources: [.discovery],
            status: .unread,
            isArchived: record.isArchived,
            isFork: record.isFork,
            pushedAt: record.pushedAt,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            libraryUpdatedAt: nil,
            firstObservedAt: nil,
            // Discovery 的缓存时间同样不能参与 Weekly 时间窗判断。
            latestObservedAt: nil,
            normalizedSearchText: normalizedSearchText(
                fullName: record.fullName,
                description: record.description,
                language: record.language,
                topics: topics,
                status: nil
            )
        )
    }

    /// 保留主表中的用户关系，同时合并公共来源和缺失元数据。
    private static func merge(
        _ incoming: AgentRepositoryCandidate,
        into merged: inout [Int64: AgentRepositoryCandidate]
    ) {
        guard var existing = merged[incoming.id] else {
            merged[incoming.id] = incoming
            return
        }
        existing.sources.formUnion(incoming.sources)
        let sourceIDs = Set((existing.snapshot.sourceIDs ?? []) + (incoming.snapshot.sourceIDs ?? []))
        existing.snapshot.sourceIDs = sourceIDs.sorted()
        existing.firstObservedAt = minISO(existing.firstObservedAt, incoming.firstObservedAt)
        existing.latestObservedAt = maxISO(existing.latestObservedAt, incoming.latestObservedAt)
        existing.snapshot.firstObservedAt = existing.firstObservedAt
        existing.snapshot.latestObservedAt = existing.latestObservedAt
        if existing.ownerAvatar == nil { existing.ownerAvatar = incoming.ownerAvatar }
        if existing.snapshot.description == nil { existing.snapshot.description = incoming.snapshot.description }
        if existing.snapshot.language == nil { existing.snapshot.language = incoming.snapshot.language }
        if existing.snapshot.topics.isEmpty { existing.snapshot.topics = incoming.snapshot.topics }
        existing.snapshot.starsCount = max(existing.snapshot.starsCount, incoming.snapshot.starsCount)
        existing.normalizedSearchText = normalizedSearchText(
            fullName: existing.fullName,
            description: existing.snapshot.description,
            language: existing.language,
            topics: existing.snapshot.topics,
            status: existing.status.rawValue
        )
        merged[incoming.id] = existing
    }

    private static func normalizedSearchText(
        fullName: String,
        description: String?,
        language: String?,
        topics: [String],
        status: String?
    ) -> String {
        RAGMentionCandidate.normalize([
            fullName,
            description ?? "",
            language ?? "",
            topics.joined(separator: " "),
            status ?? ""
        ].joined(separator: " "))
    }

    private static func decodeTopics(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private static func minISO(_ lhs: String?, _ rhs: String?) -> String? {
        switch (lhs, rhs) {
        case (nil, let value), (let value, nil): return value
        case (let left?, let right?): return min(left, right)
        }
    }

    private static func maxISO(_ lhs: String?, _ rhs: String?) -> String? {
        switch (lhs, rhs) {
        case (nil, let value), (let value, nil): return value
        case (let left?, let right?): return max(left, right)
        }
    }
}

/// Agent 选择器的纯逻辑快照，便于 ViewModel 和单测共用。
struct AgentRepositoryPickerSnapshot: Sendable {
    var suggestions: [AgentRepositoryCandidate]
    var totalCount: Int
    var matchCount: Int
    var displayedCount: Int
    var isTruncated: Bool

    static let empty = AgentRepositoryPickerSnapshot(
        suggestions: [],
        totalCount: 0,
        matchCount: 0,
        displayedCount: 0,
        isTruncated: false
    )
}

/// 已完成排序和筛选的中间结果。选择/取消仓库只基于这份缓存生成最多 80 行，
/// 不能再次扫描和排序 6,000+ 全量目录。
struct AgentRepositoryPickerMatches: Sendable {
    var candidates: [AgentRepositoryCandidate]
    var candidateIDs: Set<Int64>
}

enum AgentRepositoryPickerLogic {
    static let unselectedDisplayLimit = RAGMentionPickerLogic.unselectedDisplayLimit

    static func build(
        candidates: [AgentRepositoryCandidate],
        selected: [AIComposerRepoReference],
        query: String,
        filters: RAGComposerMentionFilters,
        selectedSources: Set<AgentRepositorySource>,
        sort: RepoSortOption
    ) -> AgentRepositoryPickerSnapshot {
        let ordered = ordered(candidates: candidates, sort: sort)
        let matches = matched(
            orderedCandidates: ordered,
            query: query,
            filters: filters,
            selectedSources: selectedSources
        )
        let candidatesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        return present(
            candidatesByID: candidatesByID,
            matches: matches,
            selected: selected,
            totalCount: candidates.count
        )
    }

    /// 排序只依赖目录和排序选项。查询、筛选和选择变化都复用该顺序，避免每次
    /// 点击筛选项都重新执行全量 `sorted`。
    static func ordered(
        candidates: [AgentRepositoryCandidate],
        sort: RepoSortOption
    ) -> [AgentRepositoryCandidate] {
        candidates.sorted { compare($0, $1, sort: sort) }
    }

    /// 在已经排好序的目录上做一次线性筛选，结果天然保留当前排序。
    static func matched(
        orderedCandidates: [AgentRepositoryCandidate],
        query: String,
        filters: RAGComposerMentionFilters,
        selectedSources: Set<AgentRepositorySource>
    ) -> AgentRepositoryPickerMatches {
        let normalizedQuery = RAGMentionCandidate.normalize(query)
        let candidates = orderedCandidates.filter { candidate in
            (normalizedQuery.isEmpty || candidate.normalizedSearchText.contains(normalizedQuery))
                && matches(candidate, filters: filters, selectedSources: selectedSources)
        }
        return AgentRepositoryPickerMatches(
            candidates: candidates,
            candidateIDs: Set(candidates.map(\.id))
        )
    }

    /// 将已选仓库置顶并截取展示窗口。这里故意只遍历到凑满 80 条为止；选择、取消、
    /// 清空只走该方法，不能让轻量 UI 操作退化成全目录过滤和排序。
    static func present(
        candidatesByID: [Int64: AgentRepositoryCandidate],
        matches: AgentRepositoryPickerMatches,
        selected: [AIComposerRepoReference],
        totalCount: Int
    ) -> AgentRepositoryPickerSnapshot {
        let selectedCandidates = selected.map { reference in
            candidatesByID[reference.id] ?? fallbackCandidate(reference)
        }
        let selectedIDs = Set(selectedCandidates.map(\.id))
        let selectedMatchCount = selectedIDs.reduce(into: 0) { count, id in
            if matches.candidateIDs.contains(id) { count += 1 }
        }
        let unselectedMatchCount = matches.candidates.count - selectedMatchCount
        var visibleUnselected: [AgentRepositoryCandidate] = []
        visibleUnselected.reserveCapacity(min(unselectedDisplayLimit, unselectedMatchCount))
        for candidate in matches.candidates where !selectedIDs.contains(candidate.id) {
            visibleUnselected.append(candidate)
            if visibleUnselected.count == unselectedDisplayLimit { break }
        }
        let suggestions = selectedCandidates + visibleUnselected
        return AgentRepositoryPickerSnapshot(
            suggestions: suggestions,
            totalCount: totalCount,
            matchCount: matches.candidates.count,
            displayedCount: suggestions.count,
            isTruncated: unselectedMatchCount > visibleUnselected.count
        )
    }

    private static func matches(
        _ candidate: AgentRepositoryCandidate,
        filters: RAGComposerMentionFilters,
        selectedSources: Set<AgentRepositorySource>
    ) -> Bool {
        // 来源多选采用 OR：候选命中任一已选来源即可；空集合表示不按来源收窄。
        if !selectedSources.isEmpty, candidate.sources.isDisjoint(with: selectedSources) { return false }
        if filters.hideArchived, candidate.isArchived { return false }
        if filters.hideForks, candidate.isFork { return false }
        if let status = filters.status, candidate.status != status { return false }
        switch filters.star {
        case .all: break
        case .starred where !candidate.snapshot.isStarred: return false
        case .unstarred where candidate.snapshot.isStarred: return false
        default: break
        }
        if !filters.selectedLanguages.isEmpty {
            guard let language = candidate.language,
                  filters.selectedLanguages.contains(where: {
                      $0.caseInsensitiveCompare(language) == .orderedSame
                  })
            else { return false }
        }
        return true
    }

    private static func compare(
        _ lhs: AgentRepositoryCandidate,
        _ rhs: AgentRepositoryCandidate,
        sort: RepoSortOption
    ) -> Bool {
        switch sort {
        case .nameAsc:
            return lhs.fullName.localizedCaseInsensitiveCompare(rhs.fullName) == .orderedAscending
        case .nameDesc:
            return lhs.fullName.localizedCaseInsensitiveCompare(rhs.fullName) == .orderedDescending
        case .starsDesc:
            return lhs.starsCount == rhs.starsCount ? lhs.id > rhs.id : lhs.starsCount > rhs.starsCount
        case .starsAsc:
            return lhs.starsCount == rhs.starsCount ? lhs.id > rhs.id : lhs.starsCount < rhs.starsCount
        case .updatedAsc:
            return ascending(lhs.pushedAt ?? lhs.updatedAt, rhs.pushedAt ?? rhs.updatedAt)
        case .createdDesc:
            return descending(lhs.createdAt, rhs.createdAt)
        case .createdAsc:
            return ascending(lhs.createdAt, rhs.createdAt)
        case .libraryUpdatedAtDesc:
            return descending(lhs.libraryUpdatedAt, rhs.libraryUpdatedAt)
        case .starredAtAsc:
            return ascending(lhs.snapshot.starredAt, rhs.snapshot.starredAt)
        case .starredAtDesc:
            return descending(lhs.snapshot.starredAt ?? lhs.latestObservedAt, rhs.snapshot.starredAt ?? rhs.latestObservedAt)
        case .updatedDesc, .healthScoreDesc, .openSSFScoreDesc:
            // Agent 目录没有 Health / OpenSSF 聚合分；这两个排序不会暴露在 Agent UI，
            // 仍提供稳定的最近事实 fallback，避免非法状态导致排序无序。
            return descending(lhs.pushedAt ?? lhs.updatedAt ?? lhs.latestObservedAt,
                              rhs.pushedAt ?? rhs.updatedAt ?? rhs.latestObservedAt)
        }
    }

    private static func descending(_ lhs: String?, _ rhs: String?) -> Bool {
        let left = lhs ?? ""
        let right = rhs ?? ""
        return left == right ? false : left > right
    }

    private static func ascending(_ lhs: String?, _ rhs: String?) -> Bool {
        let left = lhs ?? "\u{FFFD}"
        let right = rhs ?? "\u{FFFD}"
        return left == right ? false : left < right
    }

    private static func fallbackCandidate(_ reference: AIComposerRepoReference) -> AgentRepositoryCandidate {
        AgentRepositoryCandidate(
            snapshot: AgentRepoSnapshot(
                id: reference.id,
                owner: reference.owner,
                name: reference.name,
                fullName: reference.fullName,
                description: nil,
                language: reference.language,
                starsCount: reference.starsCount,
                topics: [],
                isPrivate: false,
                isStarred: false,
                starredAt: nil,
                htmlUrl: GitHubURLs.repo(fullName: reference.fullName).absoluteString,
                sourceIDs: nil,
                firstObservedAt: nil,
                latestObservedAt: nil
            ),
            ownerAvatar: nil,
            sources: [],
            status: .unread,
            isArchived: false,
            isFork: false,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            libraryUpdatedAt: nil,
            firstObservedAt: nil,
            latestObservedAt: nil,
            normalizedSearchText: RAGMentionCandidate.normalize(reference.fullName)
        )
    }
}

private extension RAGMentionCandidate {
    init(agentCandidate candidate: AgentRepositoryCandidate) {
        id = candidate.id
        owner = candidate.owner
        name = candidate.name
        fullName = candidate.fullName
        language = candidate.language
        starsCount = candidate.starsCount
        ownerAvatar = candidate.ownerAvatar
        chunkCount = 0
        hasAISummary = false
        hasPrivateNote = false
        normalizedSearchText = candidate.normalizedSearchText
    }
}
