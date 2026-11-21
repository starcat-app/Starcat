//
//  InsightsKnowledgeProfile.swift
//  Starcat
//
//  将年报共用的冻结事实投影为原生洞察。主题、数字和下钻列表共享仓库身份。
//

import Foundation
import Observation

/// 相邻的两个 30 个自然日窗口，最近一期含今天，实际数据截至本次查询。
struct InsightsProfileRequest: Hashable, Sendable {
    let accountID: Int64
    let databaseRevision: UInt64
    let scope: InsightsScope
    let timeZone: TimeZone
    let window: DateInterval
    let recentStart: Date

    init(accountID: Int64, scope: InsightsScope, day: Date, timeZone: TimeZone, databaseRevision: UInt64 = 0) {
        self.accountID = accountID
        self.databaseRevision = databaseRevision
        self.scope = scope
        self.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: day)
        recentStart = calendar.date(byAdding: .day, value: -29, to: today)!
        window = DateInterval(start: calendar.date(byAdding: .day, value: -59, to: today)!,
                              end: calendar.date(byAdding: .day, value: 1, to: today)!)
    }

    /// 进入画像才读取全量主题，年报与洞察使用同一 GRDB 读事务入口。
    func load(database: any DatabaseManaging, cutoff: Date = Date()) async throws -> InsightsKnowledgeProfile {
        let facts = try await KnowledgeProfileFactsProvider(database: database)
            .fetch(window: window, timeZone: timeZone, accountID: accountID, scope: scope, cutoff: cutoff)
        try Task.checkCancellation()
        return InsightsKnowledgeProfile(request: self, facts: facts)
    }
}

/// 仅当前选中的主题生成明细。选择器可列出全部主题，历史独有的主题也有入口。
struct InsightsKnowledgeProfile: Sendable {
    enum ThemeID: Hashable { case all, named(String), unclassified }
    struct Theme: Identifiable, Sendable {
        let id: ThemeID
        let current: [Int64]
        let starredInPeriod: [Int64]
    }
    enum Period: CaseIterable { case recent, previous }
    struct ThemeComparison: Identifiable, Sendable {
        let id: ThemeID
        let recent: Int?
        let previous: Int?

        func count(in period: Period) -> Int? {
            period == .recent ? recent : previous
        }
    }
    enum Metric: Hashable, Identifiable {
        case projects, inLibrary, using, manualNotes, aiNotes, summaries, representatives
        case starActions(Period), starredProjects(Period), writtenProjects(Period)
        var id: Self { self }
    }
    struct Match: Sendable {
        let repoID: Int64
        let fullName: String?
        let date: Date?
        var representativeReason: RepresentativeReason? = nil

        var repositoryLink: RepositoryDeepLink? {
            fullName.flatMap { RepositoryDeepLink(fullName: $0, repositoryID: repoID) }
        }

        enum RepresentativeReason: Int {
            case recentlyRecorded, using, manualNote
        }
    }
    struct Evidence {
        let rows: [Metric: [Match]]
        let unknown: Set<Metric>

        /// 人工笔记和在用状态更能解释一个仓库为何具有代表性。每组沿用明细的日期及 ID 顺序。
        var representativePreview: [Match] {
            let matches = rows[.representatives, default: []]
            var preview: [Match] = []
            for reason: Match.RepresentativeReason? in [.manualNote, .using, .recentlyRecorded, nil] {
                preview.append(contentsOf: matches.lazy.filter { $0.representativeReason == reason }.prefix(3 - preview.count))
                if preview.count == 3 { break }
            }
            return preview
        }

        /// 空的当前集合可以显示 0，历史覆盖不足且没有匹配证据时显示缺记录。
        func count(_ metric: Metric) -> Int? {
            unknown.contains(metric) ? nil : rows[metric, default: []].count
        }
    }

    let request: InsightsProfileRequest
    let facts: KnowledgeProfileFacts
    let all: Theme
    let themes: [KnowledgeProfileFacts.Dimension: [Theme]]
    private let metadata: [Int64: KnowledgeProfileFacts.Repository]
    private let events: [Int64: [KnowledgeProfileFacts.Event]]
    private let starsByPeriod: [Period: Set<Int64>]

    init(request: InsightsProfileRequest, facts: KnowledgeProfileFacts) {
        self.request = request
        self.facts = facts
        metadata = Dictionary(uniqueKeysWithValues: facts.repositories.map { ($0.id, $0) })
        // 账本按日期倒序。当前范围的代表仓库按最近可证明的动作排序，同时间按仓库 ID。
        events = Dictionary(grouping: facts.events, by: \.repoID)
        starsByPeriod = Dictionary(grouping: facts.starEvents) {
            $0.date >= request.recentStart ? Period.recent : .previous
        }.mapValues { Set($0.map(\.repoID)) }
        let members = facts.currentMembers.map(\.id)
        let memberIDs = Set(members)
        func scopedStars(_ ids: [Int64]) -> [Int64] {
            request.scope == .starred ? ids : ids.filter(memberIDs.contains)
        }
        all = Theme(id: .all, current: members, starredInPeriod: scopedStars(facts.starredRepoIDs.sorted()))
        var dimensions: [KnowledgeProfileFacts.Dimension: [Theme]] = [:]
        for dimension in KnowledgeProfileFacts.Dimension.allCases {
            let current = facts.groups(by: dimension, members: .current)
            let history = facts.groups(by: dimension, members: .starredInPeriod)
            dimensions[dimension] = Set(current.keys).union(history.keys).compactMap { name -> Theme? in
                let members = current[name, default: []]
                let stars = scopedStars(history[name, default: []])
                guard !members.isEmpty || !stars.isEmpty else { return nil }
                return Theme(id: name.map(ThemeID.named) ?? .unclassified, current: members, starredInPeriod: stars)
            }.sorted {
                if $0.current.count != $1.current.count { return $0.current.count > $1.current.count }
                if $0.starredInPeriod.count != $1.starredInPeriod.count { return $0.starredInPeriod.count > $1.starredInPeriod.count }
                if case let (.named(lhs), .named(rhs)) = ($0.id, $1.id) { return lhs < rhs }
                return $1.id == .unclassified && $0.id != .unclassified
            }
        }
        themes = dimensions
    }

    /// 主题预览只数该期不同仓库，与点开主题后的「收藏涉及的仓库」使用相同成员。
    func observedStars(for theme: Theme, period: Period) -> Int? {
        let candidates = starsByPeriod[period, default: []]
        let count = theme.starredInPeriod.lazy.filter(candidates.contains).count
        return count > 0 || facts.starCoverage == .complete ? count : nil
    }

    /// 主题变化按两期的实测仓库数排序，和主题选择器的当前存量顺序独立。
    func comparisons(by dimension: KnowledgeProfileFacts.Dimension) -> [ThemeComparison] {
        themes[dimension, default: []].compactMap { theme in
            guard !theme.starredInPeriod.isEmpty else { return nil }
            return ThemeComparison(id: theme.id, recent: observedStars(for: theme, period: .recent),
                                   previous: observedStars(for: theme, period: .previous))
        }.sorted { lhs, rhs in
            if lhs.id == .unclassified { return false }
            if rhs.id == .unclassified { return true }
            if lhs.recent != rhs.recent { return (lhs.recent ?? -1) > (rhs.recent ?? -1) }
            if lhs.previous != rhs.previous { return (lhs.previous ?? -1) > (rhs.previous ?? -1) }
            if case let (.named(left), .named(right)) = (lhs.id, rhs.id) { return left < right }
            return false
        }
    }

    /// 每项数字直接取明细长度。动作保留重复 Star，仓库指标在各自期间内单独去重。
    func evidence(for theme: Theme) -> Evidence {
        var rows: [Metric: [Match]] = [:]
        var representatives: [Int64: Match] = [:]
        for repoID in theme.current {
            guard let repo = metadata[repoID] else { continue }
            let actions = events[repoID, default: []]
            let match = Match(repoID: repoID, fullName: repo.fullName, date: actions.first?.date,
                              representativeReason: representativeReason(for: repo, hasAction: !actions.isEmpty))
            representatives[repoID] = match
            rows[.projects, default: []].append(match)
            if repo.inLibrary { rows[.inLibrary, default: []].append(match) }
            if repo.using { rows[.using, default: []].append(match) }
            if repo.note == .manual { rows[.manualNotes, default: []].append(match) }
            if repo.note == .ai { rows[.aiNotes, default: []].append(match) }
            if repo.hasSummary { rows[.summaries, default: []].append(match) }
            var written: Set<Period> = []
            for event in actions where event.action == .wroteNote || event.action == .editedNote {
                let period = period(for: event.date)
                if written.insert(period).inserted {
                    rows[.writtenProjects(period), default: []].append(
                        Match(repoID: repoID, fullName: repo.fullName, date: event.date))
                }
            }
        }
        for repoID in theme.starredInPeriod {
            var starred: Set<Period> = []
            let actions = events[repoID, default: []]
            for event in actions where event.action == .star {
                let period = period(for: event.date)
                let match = Match(repoID: repoID, fullName: metadata[repoID]?.fullName ?? event.fullName, date: event.date)
                rows[.starActions(period), default: []].append(match)
                if starred.insert(period).inserted { rows[.starredProjects(period), default: []].append(match) }
                if representatives[repoID] == nil {
                    representatives[repoID] = Match(repoID: repoID, fullName: match.fullName, date: actions.first?.date,
                                                    representativeReason: .recentlyRecorded)
                }
            }
        }
        // 完整明细保留动作的时间顺序。首页优先展示整理过的代表项目，但共用同一批仓库。
        rows[.representatives] = Array(representatives.values)
        rows = rows.mapValues { matches in
            matches.sorted {
                if $0.date == $1.date { return $0.repoID < $1.repoID }
                return ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
            }
        }
        var unknown: Set<Metric> = []
        for period in Period.allCases {
            let start = period == .recent ? request.recentStart : request.window.start
            if facts.starCoverage != .complete {
                for metric in [Metric.starActions(period), .starredProjects(period)] where rows[metric] == nil {
                    unknown.insert(metric)
                }
            }
            if rows[.writtenProjects(period)] == nil && (facts.localCollectionStartedAt > start || facts.cutoff < start) {
                unknown.insert(.writtenProjects(period))
            }
        }
        return Evidence(rows: rows, unknown: unknown)
    }

    private func representativeReason(for repo: KnowledgeProfileFacts.Repository, hasAction: Bool) -> Match.RepresentativeReason? {
        if repo.note == .manual { return .manualNote }
        if repo.using { return .using }
        return hasAction ? .recentlyRecorded : nil
    }

    private func period(for date: Date) -> Period {
        date >= request.recentStart ? .recent : .previous
    }
}

/// 右栏和刷新按钮共享加载状态。同一查询刷新时保留内容，切换账号或范围时只能取到匹配的结果。
@MainActor @Observable
final class InsightsProfileLoader {
    private var profile: InsightsKnowledgeProfile?
    private(set) var loading: InsightsProfileRequest?
    private(set) var failed: InsightsProfileRequest?
    private var generation = 0

    func displayed(for request: InsightsProfileRequest?) -> InsightsKnowledgeProfile? {
        profile?.request == request ? profile : nil
    }

    /// 手动刷新可能与上一次读取交叠，取消或迟到的查询均不能改写新范围的状态。
    func load(_ request: InsightsProfileRequest,
              read: (InsightsProfileRequest) async throws -> InsightsKnowledgeProfile) async {
        generation += 1
        let ticket = generation
        if profile?.request != request { profile = nil }
        loading = request
        failed = nil
        defer { if ticket == generation { loading = nil } }
        do {
            let result = try await read(request)
            guard !Task.isCancelled, ticket == generation else { return }
            profile = result
        } catch {
            guard !Task.isCancelled, ticket == generation else { return }
            failed = request
        }
    }
}
