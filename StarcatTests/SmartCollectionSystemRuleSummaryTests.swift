//
//  SmartCollectionSystemRuleSummaryTests.swift
//  StarcatTests
//
//  内置系统集合规则摘要与 `matchesSmartCollection` 语义对齐测试。
//

import Testing
@testable import Starcat

@Suite("SmartCollectionSystemRuleSummary")
struct SmartCollectionSystemRuleSummaryTests {

    @Test("needsReview 展示 OR 语义，不再误用 template 的 AND「无 Topics」")
    func needsReviewUsesOrSemantics() {
        let lines = SmartCollectionSystemRuleSummary.lines(for: .needsReview)

        #expect(lines.contains(String.l10n("smartCollections.systemRule.matchAny")))
        #expect(lines.contains(String.l10n("smartCollections.systemRule.needsReview.lowHealth")))
        #expect(lines.contains(String.l10n("smartCollections.systemRule.needsReview.noTopics")))
        #expect(!lines.contains(String.l10n("smartCollections.rule.requireTopicsNo")))
        #expect(!lines.contains(String.l10n("smartCollections.rule.requireLicenseNo")))
    }

    @Test("highValue 展示分支条件（有/无健康度）")
    func highValueBranchLines() {
        let lines = SmartCollectionSystemRuleSummary.lines(for: .highValue)

        #expect(lines.contains(String.l10n("smartCollections.systemRule.highValue.withHealth")))
        #expect(lines.contains(String.l10n("smartCollections.systemRule.highValue.withoutHealth")))
    }
}
