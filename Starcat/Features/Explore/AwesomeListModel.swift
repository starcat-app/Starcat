//
//  AwesomeListModel.swift
//  Starcat
//
//  Awesome 列表的派生快照。后台筛选排序一次，主线程只发布当前分页窗口。
//

import Foundation
import Observation

/// 只包含当前启用筛选所需的事实；默认浏览不观察 Skills 进度或其它仓库状态字典。
struct AwesomeListQuery: Hashable, Sendable {
    var localeIdentifier = Locale.current.identifier
    var search = ""
    var section: String?
    var sort: AwesomeSortOption = .original
    var options = AwesomeGlobalFilterOptions(
        hideArchived: false, hideForks: false, starFilter: .all, libraryFilter: .all,
        languages: [], wikiFilter: .unknown, healthFilter: .unknown, openSSFFilter: .unknown
    )
    var skillFilter: RepoSkillFilter = .any
    var skillRevision: UInt64 = 0
    var starredIDs: Set<Int64> = []
    var libraryIDs: Set<Int64> = []
    var wikiAvailability: [Int64: Bool] = [:]
    var healthIDs: Set<Int64> = []
    var openSSFIDs: Set<Int64> = []
}

/// 任务身份引用数据修订而非遍历仓库，更不能在 body 中构造候选 Repo 或格式化日期。
struct AwesomeListIdentity: Hashable, Sendable {
    let revision: UInt64
    let sourceID: String?
    var query: AwesomeListQuery
}

/// SwiftUI 只消费已完成的投影；任务取消和代际检查共同阻止旧搜索覆盖新选择。
@MainActor @Observable
final class AwesomeListModel {
    private(set) var identity: AwesomeListIdentity?
    private(set) var groups: [AwesomeSectionGroup] = []
    private(set) var rows: [AwesomeDisplayItem] = []
    private(set) var rowIndices: [String: Int] = [:]
    private(set) var repositoryIDs: [Int64] = []
    private(set) var skillCandidates: [AwesomeRepositoryItem] = []
    private(set) var isUpdating = false
    private(set) var projectionRevision: UInt64 = 0
    private var matching: [AwesomeDisplayItem] = []
    private var generation: UInt64 = 0
    var total: Int { matching.count }
    var hasMore: Bool { rows.count < matching.count }

    /// 输入未变直接复用；不可把全量投影塞入 List，否则搜索清空时会一次创建几千行。
    func update(
        identity: AwesomeListIdentity,
        repositories: [AwesomeRepositoryItem],
        resources: [AwesomeResourceItem],
        skillPresence: [Int64: RepoSkillPresence] = [:]
    ) async {
        guard self.identity != identity else { return }
        generation &+= 1
        let expected = generation
        isUpdating = true
        defer { if generation == expected { isUpdating = false } }
        let result = await Self.project(
            repositories: repositories, resources: resources,
            query: identity.query, skillPresence: skillPresence
        )
        guard !Task.isCancelled, generation == expected else { return }
        let limit = self.identity?.sourceID == identity.sourceID && self.identity?.query == identity.query
            ? max(rows.count, AwesomeStore.repositoryPageSize) : AwesomeStore.repositoryPageSize
        self.identity = identity
        matching = result.items
        skillCandidates = result.candidates
        repositoryIDs = result.items.compactMap {
            if case .repository(let repo) = $0 { return repo.id }
            return nil
        }
        publishRows(limit: limit)
        projectionRevision &+= 1
    }

    /// 本地展示分页不重新筛选或排序，也不触发数据库和网络读取。
    func loadMore() {
        guard hasMore else { return }
        publishRows(limit: rows.count + AwesomeStore.repositoryPageSize)
    }

    /// 账户切换不能复用上一账户的派生结果，包含正在后台计算的旧查询。
    func reset() {
        generation &+= 1
        identity = nil
        groups = []
        rows = []
        rowIndices = [:]
        repositoryIDs = []
        skillCandidates = []
        matching = []
        isUpdating = false
        projectionRevision &+= 1
    }

    private func publishRows(limit: Int) {
        let visible = Array(matching.prefix(limit))
        if identity?.sourceID != nil, identity?.query.sort == .original, identity?.query.section == nil {
            var order: [String] = []
            var grouped: [String: [AwesomeDisplayItem]] = [:]
            for item in visible {
                let path = item.sectionPath.joined(separator: " / ")
                let title = path.isEmpty ? String.l10n("awesome.section.other") : path
                if grouped[title] == nil { order.append(title) }
                grouped[title, default: []].append(item)
            }
            groups = order.map { AwesomeSectionGroup(title: $0, items: grouped[$0] ?? []) }
        } else {
            groups = [AwesomeSectionGroup(title: String.l10n("awesome.section.results"), items: visible)]
        }
        rows = groups.flatMap(\.items)
        rowIndices = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
    }

    /// @concurrent 明确离开 MainActor；日期与证据保持值语义，不把可变 formatter 传进任务。
    @concurrent nonisolated private static func project(
        repositories: [AwesomeRepositoryItem],
        resources: [AwesomeResourceItem],
        query: AwesomeListQuery,
        skillPresence: [Int64: RepoSkillPresence]
    ) async -> Projection {
        let term = query.search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates = repositories.filter { repo in
            guard !Task.isCancelled,
                  AwesomeGlobalFilterPolicy.matches(
                    repo, options: query.options,
                    facts: AwesomeGlobalFilterFacts(
                        isStarred: query.starredIDs.contains(repo.id),
                        isInLibrary: query.libraryIDs.contains(repo.id),
                        wikiAvailability: query.wikiAvailability[repo.id],
                        hasHealthData: query.healthIDs.contains(repo.id),
                        hasOpenSSFData: query.openSSFIDs.contains(repo.id)
                    )
                  ) else { return false }
            if let section = query.section,
               !repo.evidence.contains(where: { $0.sectionPath.joined(separator: " / ") == section }) {
                return false
            }
            guard !term.isEmpty else { return true }
            if repo.fullName.lowercased().contains(term) || repo.description?.lowercased().contains(term) == true {
                return true
            }
            return repo.evidence.contains {
                [$0.entryTitle, $0.entryDescription, $0.source.displayName]
                    .contains { $0?.lowercased().contains(term) == true }
            }
        }
        var items = candidates.filter {
            query.skillFilter.matches(skillPresence[$0.id] ?? .unknown)
        }.map(AwesomeDisplayItem.repository)
        if query.options.includesResources {
            items += resources.filter { resource in
                guard !Task.isCancelled else { return false }
                if let section = query.section,
                   resource.evidence.sectionPath.joined(separator: " / ") != section { return false }
                return term.isEmpty || [resource.title, resource.description, resource.url.absoluteString]
                    .contains { $0?.lowercased().contains(term) == true }
            }.map(AwesomeDisplayItem.resource)
        }
        switch query.sort {
        case .original: items.sort(by: AwesomeDisplayItem.originalOrder)
        case .stars: items.sort(by: AwesomeDisplayItem.starOrder)
        case .updated: items.sort(by: AwesomeDisplayItem.updatedOrder)
        case .name:
            items.sort {
                let order = $0.title.localizedCaseInsensitiveCompare($1.title)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
        }
        return Projection(items: items, candidates: candidates)
    }

    private struct Projection: Sendable {
        let items: [AwesomeDisplayItem]
        let candidates: [AwesomeRepositoryItem]
    }
}
