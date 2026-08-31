//
//  SmartCollectionChipLayoutPolicyTests.swift
//  StarcatTests
//
//  锁住智能集合卡片的单行 chip 裁剪边界，避免重新引入 View 内几何测量。
//

import Testing
@testable import Starcat

@Suite("SmartCollectionChipLayoutPolicy")
struct SmartCollectionChipLayoutPolicyTests {
    @Test("全部 chip 可见时不显示省略项")
    func keepsAllChipsWhenTheyFit() {
        let decision = SmartCollectionChipLayoutPolicy.resolve(
            chipWidths: [40, 50],
            availableWidth: 96,
            spacing: 6,
            overflowWidth: 20
        )

        #expect(decision == SmartCollectionChipLayoutDecision(
            visibleChipCount: 2,
            showsOverflow: false
        ))
    }

    @Test("剩余空间有限时保留已展示 chip 和省略项")
    func reservesOverflowForHiddenChips() {
        let decision = SmartCollectionChipLayoutPolicy.resolve(
            chipWidths: [40, 50, 60],
            availableWidth: 66,
            spacing: 6,
            overflowWidth: 20
        )

        #expect(decision == SmartCollectionChipLayoutDecision(
            visibleChipCount: 1,
            showsOverflow: true
        ))
    }

    @Test("首个 chip 过宽时仍可只展示省略项")
    func fallsBackToOverflowOnly() {
        let decision = SmartCollectionChipLayoutPolicy.resolve(
            chipWidths: [80, 90],
            availableWidth: 20,
            spacing: 6,
            overflowWidth: 20
        )

        #expect(decision == SmartCollectionChipLayoutDecision(
            visibleChipCount: 0,
            showsOverflow: true
        ))
    }

    @Test("连省略项也放不下时返回空行")
    func returnsEmptyWhenNothingFits() {
        let decision = SmartCollectionChipLayoutPolicy.resolve(
            chipWidths: [80],
            availableWidth: 19,
            spacing: 6,
            overflowWidth: 20
        )

        #expect(decision == SmartCollectionChipLayoutDecision(
            visibleChipCount: 0,
            showsOverflow: false
        ))
    }
}
