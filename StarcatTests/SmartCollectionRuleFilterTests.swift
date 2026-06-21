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
        requireNote: Bool? = nil
    ) -> SmartCollectionRule {
        SmartCollectionRule(
            scope: .allStars,
            query: nil,
            searchModeRaw: SmartSearchMode.keyword.rawValue,
            statusRaw: nil,
            selectedTagIDs: [],
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
            requireNote: requireNote
        )
    }

    private static func emptyContext() -> SmartCollectionRuleFilterContext {
        SmartCollectionRuleFilterContext(
            statusMap: [:],
            repoTagsMap: [:],
            healthSnapshots: [:],
            repoIdsWithNotes: [],
            now: now
        )
    }

    private static func makeRepo(
        id: Int64,
        stars: Int = 10,
        license: String? = "MIT",
        topics: String? = "[\"swift\"]",
        pushedAt: String? = nil
    ) -> Repo {
        Repo(
            id: id,
            owner: "owner",
            name: "repo-\(id)",
            fullName: "owner/repo-\(id)",
            description: "desc",
            language: "Swift",
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
            starredAt: nil,
            cachedAt: nil
        )
    }

    private static func makeHealth(repoId: Int64, score: Double) -> RepoHealthSnapshot {
        RepoHealthSnapshot(
            repoId: repoId,
            overallScore: score,
            grade: "B",
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
