//
//  AmbientGridEngineTests.swift
//  StarcatTests
//
//  覆盖 Ambient 全局 deadline、随机槽位 bag、确定性抽卡与小卡池退化策略。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Ambient Grid Engine")
struct AmbientGridEngineTests {
    @Test("空池保留槽位但不调度")
    func emptyPoolKeepsSlotsWithoutDeadline() {
        let engine = makeEngine(cards: [], rows: 2, columns: 3)

        #expect(engine.snapshots.count == 6)
        #expect(engine.snapshots.allSatisfy { $0.card == nil && $0.nextCard == nil })
        #expect(engine.nextDeadline == nil)
    }

    @Test("单卡池推进 deadline 但不伪报视觉变化")
    func singleCardDoesNotReportVisualChange() {
        var engine = makeEngine(cards: [card(0)], rows: 1, columns: 2)
        let firstDeadline = engine.nextDeadline
        let result = engine.advance(now: firstDeadline ?? 0)

        #expect(!result.didChange)
        #expect(result.changedSlotIDs.isEmpty)
        #expect(result.snapshots.allSatisfy { $0.card?.id == "card:0" })
        #expect((result.nextDeadline ?? 0) > (firstDeadline ?? 0))
    }

    @Test("首次 deadline 默认延后两秒")
    func initialDeadlineHasLeadIn() {
        let engine = makeEngine(cards: cards(8), rows: 2, columns: 2, now: 100)

        #expect(engine.nextDeadline == 102)
    }

    @Test("全局 deadline 每三秒只轮换一个随机槽位")
    func normalDeadlineChangesOneSlot() throws {
        var engine = makeEngine(cards: cards(12), rows: 1, columns: 3, now: 100)
        let before = engine.snapshots
        let deadline = try #require(engine.nextDeadline)
        let result = engine.advance(now: deadline)
        let changedID = try #require(result.changedSlotIDs.first)

        #expect(result.changedSlotIDs.count == 1)
        #expect(result.snapshots[changedID].card?.id != before[changedID].card?.id)
        #expect(result.nextDeadline == deadline + AmbientGridConfig.defaultChangeInterval)

        let unchangedIDs = before.indices.filter { $0 != changedID }
        #expect(unchangedIDs.allSatisfy { result.snapshots[$0].card == before[$0].card })
    }

    @Test("大时间跳跃只换一格并从当前时间重新计时")
    func timeJumpDoesNotCatchUp() {
        var engine = makeEngine(cards: cards(20), rows: 2, columns: 3, now: 100)
        let result = engine.advance(now: 1_000)

        #expect(result.changedSlotIDs.count == 1)
        #expect(result.nextDeadline == 1_003)
    }

    @Test("shuffle-bag 每轮随机覆盖全部槽位且跨轮不连续重复")
    func shuffleBagIsRandomAndFair() throws {
        var engine = makeEngine(
            cards: cards(30),
            rows: 2,
            columns: 3,
            randomSeed: 7
        )
        var changedIDs: [Int] = []

        for _ in 0..<6 {
            let deadline = try #require(engine.nextDeadline)
            let result = engine.advance(now: deadline)
            changedIDs.append(try #require(result.changedSlotIDs.first))
        }

        #expect(Set(changedIDs) == Set(0..<6))
        #expect(changedIDs != Array(0..<6))

        let nextDeadline = try #require(engine.nextDeadline)
        let nextResult = engine.advance(now: nextDeadline)
        #expect(nextResult.changedSlotIDs.first != changedIDs.last)
    }

    @Test("固定 seed 的初始化和推进可复现")
    func fixedSeedIsDeterministic() throws {
        var first = makeEngine(cards: cards(10), rows: 2, columns: 3, randomSeed: 42)
        var second = makeEngine(cards: cards(10), rows: 2, columns: 3, randomSeed: 42)

        #expect(first.snapshots == second.snapshots)
        let deadline = try #require(first.nextDeadline)
        #expect(first.advance(now: deadline) == second.advance(now: deadline))
    }

    @Test("候选足够时上方和左侧邻格不共享 id 或 visualKey")
    func adjacentSlotsAvoidDuplicateArtwork() {
        let engine = makeEngine(cards: cards(20), rows: 3, columns: 4)
        let snapshots = engine.snapshots

        for index in snapshots.indices {
            let row = index / 4
            let column = index % 4
            if column > 0 {
                expectDifferent(snapshots[index], snapshots[index - 1])
            }
            if row > 0 {
                expectDifferent(snapshots[index], snapshots[index - 4])
            }
        }
    }

    @Test("候选不足时允许重复且仍能推进")
    func smallPoolDegradesWithoutLooping() throws {
        var engine = makeEngine(cards: [card(0), card(1)], rows: 5, columns: 6)

        #expect(engine.snapshots.count == 30)
        #expect(engine.snapshots.allSatisfy { $0.card != nil })
        let deadline = try #require(engine.nextDeadline)
        let result = engine.advance(now: deadline)
        #expect(result.nextDeadline != nil)
    }

    @Test("异常配置不创建负容量且修正轮换节奏")
    func invalidConfigIsSafe() {
        let noRows = AmbientGridConfig(
            rowCount: 0,
            columnCount: 5,
            changeInterval: -1,
            flipDuration: -2,
            initialLeadIn: -1
        )
        let noColumns = AmbientGridConfig(rowCount: 5, columnCount: -1)

        #expect(noRows.slotCount == 0)
        #expect(noColumns.slotCount == 0)
        #expect(noRows.changeInterval > noRows.flipDuration)
        #expect(noRows.flipDuration == 0)
        #expect(noRows.initialLeadIn == 1)
    }

    private func makeEngine(
        cards: [AmbientCardModel],
        rows: Int,
        columns: Int,
        now: TimeInterval = 100,
        randomSeed: UInt64 = 7
    ) -> AmbientGridEngine {
        AmbientGridEngine(
            cards: cards,
            config: AmbientGridConfig(rowCount: rows, columnCount: columns),
            now: now,
            randomSeed: randomSeed
        )
    }

    private func cards(_ count: Int) -> [AmbientCardModel] {
        (0..<count).map(card)
    }

    private func card(_ index: Int) -> AmbientCardModel {
        AmbientCardModel(
            id: "card:\(index)",
            visualKey: "owner:\(index)",
            title: "owner\(index)/repo\(index)",
            artworkURLString: "https://github.com/owner\(index).png",
            subtitle: nil,
            metadata: [:]
        )
    }

    private func expectDifferent(_ lhs: AmbientSlotSnapshot, _ rhs: AmbientSlotSnapshot) {
        #expect(lhs.card?.id != rhs.card?.id)
        #expect(lhs.card?.visualKey != rhs.card?.visualKey)
    }
}
