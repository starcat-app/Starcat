//
//  SmartCollectionRuleTemplateTests.swift
//  StarcatTests
//

import Testing
@testable import Starcat

@Suite("SmartCollectionRuleTemplate")
struct SmartCollectionRuleTemplateTests {

    @Test("template(for:) 映射内置集合关键字段")
    func builtInTemplates() {
        let using = SmartCollectionRule.template(for: .using)
        #expect(using.status == .using)

        let untagged = SmartCollectionRule.template(for: .noTags)
        if case .untagged = untagged.scope {
            #expect(Bool(true))
        } else {
            Issue.record("noTags template should use untagged scope")
        }

        let active = SmartCollectionRule.template(for: .recentlyActive)
        #expect(active.pushedWithinDays == 30)

        let highValue = SmartCollectionRule.template(for: .highValue)
        #expect(highValue.starsMin == 1_000)
        #expect(highValue.healthScoreMin == 75)
    }
}
