//
//  SmartCollectionRuleFilterTests.swift
//  StarcatTests
//
//  用户智能集合高阶 predicate 过滤测试。
//

import Foundation
import Testing
@testable import Starcat

@Suite("SmartCollectionRuleFilter")
struct SmartCollectionRuleFilterTests {

    /// 与 `ISO8601DateFormatter.shared`（带 fractional seconds）对齐的固定时间点。
    private static let now = ISO8601DateFormatter.shared.date(from: "2026-06-21T12:00:00.000Z")!

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter.shared.string(from: date)
    }

    @Test("starsMin / starsMax 过滤 star 数")
    func starsRangeFilter() {
        let repos = [
            Self.makeRepo(id: 1, stars: 50),
            Self.makeRepo(id: 2, stars: 150),
            Self.makeRepo(id: 3, stars: 500)
        ]
        let rule = Self.baseRule(starsMin: 100, starsMax: 400)
        let result = SmartCollectionRuleFilter.apply(repos: repos, rule: rule, context: Self.emptyContext())
        #expect(result.map(\.id) == [2])
    }

    @Test("pushedWithinDays 只保留最近推送的 repo")
    func pushedWithinDaysFilter() {
        let recent = Self.iso(Self.now.addingTimeInterval(-5 * 86_400))
        let stale = Self.iso(Self.now.addingTimeInterval(-40 * 86_400))
        let repos = [
            Self.makeRepo(id: 1, pushedAt: recent),
            Self.makeRepo(id: 2, pushedAt: stale),
            Self.makeRepo(id: 3, pushedAt: nil)
        ]
        let rule = Self.baseRule(pushedWithinDays: 30)
        let result = SmartCollectionRuleFilter.apply(repos: repos, rule: rule, context: Self.emptyContext())
        #expect(result.map(\.id) == [1])
    }

    @Test("pushedOlderThanDays 过滤长期未推送 repo")
    func pushedOlderThanDaysFilter() {
        let recent = Self.iso(Self.now.addingTimeInterval(-5 * 86_400))
        let stale = Self.iso(Self.now.addingTimeInterval(-40 * 86_400))
        let repos = [
            Self.makeRepo(id: 1, pushedAt: recent),
            Self.makeRepo(id: 2, pushedAt: stale)
        ]
        let rule = Self.baseRule(pushedOlderThanDays: 30)
        let result = SmartCollectionRuleFilter.apply(repos: repos, rule: rule, context: Self.emptyContext())
        #expect(result.map(\.id) == [2])
    }

    @Test("healthScoreMin / healthScoreMax 过滤健康分")
    func healthScoreFilter() {
        let repos = [
            Self.makeRepo(id: 1),
            Self.makeRepo(id: 2),
            Self.makeRepo(id: 3)
        ]
        var context = Self.emptyContext()
        context.healthSnapshots = [
            1: Self.makeHealth(repoId: 1, score: 40),
            2: Self.makeHealth(repoId: 2, score: 75),
            3: Self.makeHealth(repoId: 3, score: 95)
        ]
        let rule = Self.baseRule(healthScoreMin: 60, healthScoreMax: 90)
        let result = SmartCollectionRuleFilter.apply(repos: repos, rule: rule, context: context)
        #expect(result.map(\.id) == [2])
    }

    @Test("healthScoreMin 在空 health context 下会误滤掉全部 repo（context 必须按 merged rule 加载）")
    func healthScoreMinRequiresHealthContext() {
        let repos = [
            Self.makeRepo(id: 1),
            Self.makeRepo(id: 2)
        ]
        var contextWithHealth = Self.emptyContext()
        contextWithHealth.healthSnapshots = [
            1: Self.makeHealth(repoId: 1, score: 40),
            2: Self.makeHealth(repoId: 2, score: 80)
        ]
        let rule = Self.baseRule(healthScoreMin: 60)
        #expect(SmartCollectionRuleFilter.apply(repos: repos, rule: rule, context: contextWithHealth).map(\.id) == [2])
        #expect(SmartCollectionRuleFilter.apply(repos: repos, rule: rule, context: Self.emptyContext()).isEmpty)
    }

    @Test("requireLicense / requireTopics / requireNote 三态过滤")
    func metadataTriStateFilters() {
        let repos = [
            Self.makeRepo(id: 1, license: "MIT", topics: "[\"swift\"]"),
            Self.makeRepo(id: 2, license: nil, topics: nil),
            Self.makeRepo(id: 3, license: "MIT", topics: nil)
        ]
        var context = Self.emptyContext()
        context.repoIdsWithNotes = [1]

        let licenseRule = Self.baseRule(requireLicense: true)
        #expect(SmartCollectionRuleFilter.apply(repos: repos, rule: licenseRule, context: context).map(\.id) == [1, 3])

        let noLicenseRule = Self.baseRule(requireLicense: false)
        #expect(SmartCollectionRuleFilter.apply(repos: repos, rule: noLicenseRule, context: context).map(\.id) == [2])

        let topicsRule = Self.baseRule(requireTopics: true)
        #expect(SmartCollectionRuleFilter.apply(repos: repos, rule: topicsRule, context: context).map(\.id) == [1])

        let noteRule = Self.baseRule(requireNote: true)
        #expect(SmartCollectionRuleFilter.apply(repos: repos, rule: noteRule, context: context).map(\.id) == [1])

        let noNoteRule = Self.baseRule(requireNote: false)
        #expect(SmartCollectionRuleFilter.apply(repos: repos, rule: noNoteRule, context: context).map(\.id) == [2, 3])
    }

    @Test("healthGrades 按项目健康度等级过滤")
    func healthGradesFilter() {
        let repos = [
            Self.makeRepo(id: 1),
            Self.makeRepo(id: 2),
            Self.makeRepo(id: 3)
        ]
        var context = Self.emptyContext()
        context.healthSnapshots = [
            1: Self.makeHealth(repoId: 1, score: 95, grade: "A"),
            2: Self.makeHealth(repoId: 2, score: 75, grade: "C"),
            3: Self.makeHealth(repoId: 3, score: 55, grade: "E")
        ]
        var rule = Self.baseRule()
        rule.healthGrades = ["A", "B"]
        #expect(SmartCollectionRuleFilter.apply(repos: repos, rule: rule, context: context).map(\.id) == [1])
    }

    @Test("starredWithinDays / filterLanguages / tagMatch all")
    func v22Filters() {
        let recentStar = Self.iso(Self.now.addingTimeInterval(-3 * 86_400))
        let oldStar = Self.iso(Self.now.addingTimeInterval(-90 * 86_400))
        let repos = [
            Self.makeRepo(id: 1, language: "Swift", starredAt: recentStar),
            Self.makeRepo(id: 2, language: "Go", starredAt: oldStar),
            Self.makeRepo(id: 3, language: "Swift", starredAt: oldStar)
        ]
        var context = Self.emptyContext()
        context.repoTagsMap = [
            1: ["t1", "t2"],
            2: ["t1"],
            3: ["t2"]
        ]

        let starredRule = Self.baseRule(starredWithinDays: 30)
        #expect(SmartCollectionRuleFilter.apply(repos: repos, rule: starredRule, context: context).map(\.id) == [1])

        let langRule = Self.baseRule(filterLanguages: ["Swift"])
        #expect(SmartCollectionRuleFilter.apply(repos: repos, rule: langRule, context: context).map(\.id) == [1, 3])

        var allTagsRule = Self.baseRule(selectedTagIDs: ["t1", "t2"])
        allTagsRule.tagMatchModeRaw = SmartCollectionTagMatchMode.all.rawValue
        #expect(SmartCollectionRuleFilter.apply(repos: repos, rule: allTagsRule, context: context).map(\.id) == [1])
    }

    @Test("topicContains / excludedTagIDs / semanticScoreMin")
    func v24Filters() {
        let repos = [
            Self.makeRepo(id: 1, topics: "[\"machine-learning\"]"),
            Self.makeRepo(id: 2, topics: "[\"swift\"]")
        ]
        var context = Self.emptyContext()
        context.repoTagsMap = [1: ["keep"], 2: ["drop"]]
        context.semanticHitMap = [
            1: SemanticSearchHit(repo: repos[0], score: 0.8, displayScore: 0.82, tier: 3, reason: "test"),
            2: SemanticSearchHit(repo: repos[1], score: 0.4, displayScore: 0.45, tier: 2, reason: "test")
        ]

        let topicRule = Self.baseRule(topicContains: "machine")
        #expect(SmartCollectionRuleFilter.apply(repos: repos, rule: topicRule, context: context).map(\.id) == [1])

        let excludeRule = Self.baseRule(excludedTagIDs: ["drop"])
        #expect(SmartCollectionRuleFilter.apply(repos: repos, rule: excludeRule, context: context).map(\.id) == [1])

        let semanticRule = Self.baseRule(semanticScoreMin: 50)
        #expect(SmartCollectionRuleFilter.apply(repos: repos, rule: semanticRule, context: context).map(\.id) == [1])
    }

    // MARK: - Helpers

    private static func baseRule(
        starsMin: Int? = nil,
        starsMax: Int? = nil,
        pushedWithinDays: Int? = nil,
        pushedOlderThanDays: Int? = nil,
        healthScoreMin: Int? = nil,
        healthScoreMax: Int? = nil,
        requireLicense: Bool? = nil,
        requireTopics: Bool? = nil,
        requireNote: Bool? = nil,
        starredWithinDays: Int? = nil,
        filterLanguages: [String] = [],
        selectedTagIDs: [String] = [],
        excludedTagIDs: [String] = [],
        topicContains: String? = nil,
        semanticScoreMin: Int? = nil
    ) -> SmartCollectionRule {
        SmartCollectionRule(
            scope: .allStars,
            query: nil,
            searchModeRaw: SmartSearchMode.keyword.rawValue,
            statusRaw: nil,
            selectedTagIDs: selectedTagIDs,
            hideArchived: false,
            hideForks: false,
            sortRaw: RepoSortOption.starredAtDesc.rawValue,
            starsMin: starsMin,
            starsMax: starsMax,
            pushedWithinDays: pushedWithinDays,
            pushedOlderThanDays: pushedOlderThanDays,
            healthScoreMin: healthScoreMin,
            healthScoreMax: healthScoreMax,
            requireLicense: requireLicense,
            requireTopics: requireTopics,
            requireNote: requireNote,
            starredWithinDays: starredWithinDays,
            filterLanguages: filterLanguages,
            excludedTagIDs: excludedTagIDs,
            topicContains: topicContains,
            semanticScoreMin: semanticScoreMin
        )
    }

    private static func emptyContext() -> SmartCollectionRuleFilterContext {
        SmartCollectionRuleFilterContext(
            statusMap: [:],
            repoTagsMap: [:],
            healthSnapshots: [:],
            repoIdsWithNotes: [],
            openSSFScores: [:],
            latestReleasePublishedAt: [:],
            semanticHitMap: [:],
            now: now
        )
    }

    private static func makeRepo(
        id: Int64,
        stars: Int = 10,
        license: String? = "MIT",
        topics: String? = "[\"swift\"]",
        pushedAt: String? = nil,
        language: String? = "Swift",
        starredAt: String? = nil
    ) -> Repo {
        Repo(
            id: id,
            owner: "owner",
            name: "repo-\(id)",
            fullName: "owner/repo-\(id)",
            description: "desc",
            language: language,
            starsCount: stars,
            forksCount: 0,
            watchersCount: 0,
            topics: topics,
            license: license,
            homepage: nil,
            htmlUrl: "https://github.com/owner/repo-\(id)",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: true,
            pushedAt: pushedAt,
            createdAt: nil,
            updatedAt: nil,
            starredAt: starredAt,
            cachedAt: nil
        )
    }

    private static func makeHealth(repoId: Int64, score: Double, grade: String = "B") -> RepoHealthSnapshot {
        RepoHealthSnapshot(
            repoId: repoId,
            overallScore: score,
            grade: grade,
            maintenanceScore: score,
            popularityScore: score,
            qualityScore: score,
            securityScore: score,
            payloadJSON: "{}",
            computedAt: Self.iso(Self.now),
            staleAfter: Self.iso(Self.now.addingTimeInterval(86_400)),
            fetchStatus: .success,
            lastError: nil
        )
    }
}
