//
//  SmartCollectionRuleSummaryTests.swift
//  StarcatTests
//
//  用户智能集合规则摘要格式化测试。
//

import Testing
@testable import Starcat

@Suite("SmartCollectionRuleSummary")
struct SmartCollectionRuleSummaryTests {

    @Test("lines 覆盖 scope / 搜索 / 标签 / 状态 / 隐藏项 / 排序")
    func summaryLines() {
        let context = SmartCollectionRuleSummary.Context { id in
            id == "tag-a" ? "iOS" : id
        }
        let rule = SmartCollectionRule(
            scope: .language("Swift"),
            query: "database",
            searchModeRaw: SmartSearchMode.keyword.rawValue,
            statusRaw: RepoStatus.using.rawValue,
            selectedTagIDs: ["tag-a", "tag-b"],
            hideArchived: true,
            hideForks: false,
            sortRaw: RepoSortOption.updatedDesc.rawValue
        )

        let lines = SmartCollectionRuleSummary.lines(rule: rule, context: context)
        #expect(lines.count >= 4)
        #expect(lines[0].contains("Swift"))
        #expect(lines.contains { $0.contains("database") })
        #expect(lines.contains { $0.contains("iOS") })
        #expect(lines.contains { $0.contains(RepoStatus.using.localizedDisplayName) })
        #expect(lines.last?.contains(RepoSortOption.updatedDesc.localizedTitle) == true)
    }

    @Test("lines 覆盖高阶 predicate 摘要")
    func advancedSummaryLines() {
        let context = SmartCollectionRuleSummary.Context { _ in "Tag" }
        let rule = SmartCollectionRule(
            scope: .allStars,
            query: nil,
            searchModeRaw: SmartSearchMode.keyword.rawValue,
            statusRaw: nil,
            selectedTagIDs: [],
            hideArchived: false,
            hideForks: false,
            sortRaw: RepoSortOption.starredAtDesc.rawValue,
            starsMin: 100,
            starsMax: 10_000,
            pushedWithinDays: 30,
            pushedOlderThanDays: nil,
            healthScoreMin: 60,
            healthScoreMax: nil,
            requireLicense: true,
            requireTopics: false,
            requireNote: true
        )

        let lines = SmartCollectionRuleSummary.lines(rule: rule, context: context)
        #expect(lines.contains { $0.contains("100") && $0.contains("10000") || $0.contains("10,000") })
        #expect(lines.contains { $0.contains("30") })
        #expect(lines.contains { $0.contains("60") })
        #expect(lines.contains { $0 == String.l10n("smartCollections.rule.requireLicenseYes") })
        #expect(lines.contains { $0 == String.l10n("smartCollections.rule.requireTopicsNo") })
        #expect(lines.contains { $0 == String.l10n("smartCollections.rule.requireNoteYes") })
    }

    @Test("compact 用分隔符合并多行")
    func compactSummary() {
        let context = SmartCollectionRuleSummary.Context { _ in "Tag" }
        let rule = SmartCollectionRule(
            scope: .allStars,
            query: nil,
            searchModeRaw: SmartSearchMode.keyword.rawValue,
            statusRaw: nil,
            selectedTagIDs: [],
            hideArchived: false,
            hideForks: false,
            sortRaw: RepoSortOption.starredAtDesc.rawValue
        )
        let compact = SmartCollectionRuleSummary.compact(rule: rule, context: context)
        #expect(!compact.isEmpty)
        #expect(compact.contains(String.l10n("smartCollections.rule.scope.allStars")))
    }
}
