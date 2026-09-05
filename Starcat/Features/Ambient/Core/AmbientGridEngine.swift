//
//  AmbientGridEngine.swift
//  Starcat
//
//  Ambient 的纯值 deadline 状态机。它预选每格下一张卡，并通过 seeded shuffle-bag
//  随机且公平地选择下一处翻转；休眠恢复时只推进一次，绝不追赶历史次数。
//

import Foundation

/// 用固定 seed 可复现的 Ambient 网格状态机。
struct AmbientGridEngine: Sendable {
    private struct Slot: Sendable {
        let id: Int
        var card: AmbientCardModel?
        var previousCard: AmbientCardModel?
        var nextCard: AmbientCardModel?
    }

    private let config: AmbientGridConfig
    private let cards: [AmbientCardModel]
    private var slots: [Slot]
    private var random: SplitMix64
    private var pendingSlotIndices: [Int] = []
    private var lastRotatedSlotIndex: Int?
    private var nextChangeAt: TimeInterval?

    init(
        cards: [AmbientCardModel],
        config: AmbientGridConfig,
        now: TimeInterval,
        randomSeed: UInt64
    ) {
        self.config = config
        self.cards = Self.uniqueCards(cards)
        random = SplitMix64(seed: randomSeed)
        slots = []
        slots.reserveCapacity(config.slotCount)

        for index in 0..<config.slotCount {
            let neighbors = neighborCards(for: index, in: slots)
            let card = pickCard(
                excludingIDs: Set(neighbors.map(\.id)),
                excludingVisualKeys: Set(neighbors.map(\.visualKey))
            )
            slots.append(Slot(
                id: index,
                card: card,
                previousCard: nil,
                nextCard: nil
            ))
        }

        for index in slots.indices {
            slots[index].nextCard = pickNextCard(for: index)
        }

        if !self.cards.isEmpty, !slots.isEmpty {
            nextChangeAt = now + config.initialLeadIn
            refillSlotBag()
        } else {
            nextChangeAt = nil
        }
    }

    var snapshots: [AmbientSlotSnapshot] {
        slots.map { slot in
            AmbientSlotSnapshot(
                id: slot.id,
                card: slot.card,
                nextCard: slot.nextCard
            )
        }
    }

    var nextDeadline: TimeInterval? {
        nextChangeAt
    }

    /// 到达全局 deadline 后，从 shuffle-bag 随机取一个尚未轮换的槽位。
    ///
    /// 每轮 bag 覆盖全部槽位，并避免跨轮连续命中同一格；这既消除从左到右的
    /// 扫描感，也避免纯随机长期遗漏某些格子。下一 deadline 始终从 `now` 重算，
    /// 因而系统休眠或主线程阻塞恢复后不会高速追帧。
    mutating func advance(now: TimeInterval) -> AmbientAdvanceResult {
        guard let nextChangeAt, nextChangeAt <= now,
              let slotIndex = nextRandomSlotIndex() else {
            return result(changedSlotIDs: [])
        }

        let changed = rotateSlot(at: slotIndex)
        self.nextChangeAt = now + config.changeInterval

        return result(changedSlotIDs: changed ? [slots[slotIndex].id] : [])
    }

    private mutating func rotateSlot(at index: Int) -> Bool {
        guard let current = slots[index].card,
              let replacement = slots[index].nextCard else { return false }

        let changed = current.id != replacement.id
        if changed {
            slots[index].previousCard = current
            slots[index].card = replacement
        }
        slots[index].nextCard = pickNextCard(for: index)
        return changed
    }

    private mutating func nextRandomSlotIndex() -> Int? {
        if pendingSlotIndices.isEmpty {
            refillSlotBag()
        }
        guard let index = pendingSlotIndices.popLast() else { return nil }
        lastRotatedSlotIndex = index
        return index
    }

    private mutating func refillSlotBag() {
        var indices = Array(slots.indices)
        guard !indices.isEmpty else {
            pendingSlotIndices = []
            return
        }

        // Fisher-Yates 使用 Engine 自己的 PRNG，保证相同 seed 下测试和屏保壳可复现。
        if indices.count > 1 {
            for upperIndex in stride(from: indices.count - 1, through: 1, by: -1) {
                let swapIndex = random.nextInt(upperBound: upperIndex + 1)
                indices.swapAt(upperIndex, swapIndex)
            }

            // `popLast()` 是下一次选择；跨轮边界不得让刚翻过的格子立即再翻一次。
            if indices.last == lastRotatedSlotIndex {
                indices.swapAt(indices.count - 1, 0)
            }
        }

        pendingSlotIndices = indices
    }

    private mutating func pickNextCard(for index: Int) -> AmbientCardModel? {
        let neighbors = neighborCards(for: index, in: slots)
        var excludedIDs = Set(neighbors.map(\.id))
        var excludedVisualKeys = Set(neighbors.map(\.visualKey))

        if let current = slots[index].card {
            excludedIDs.insert(current.id)
            excludedVisualKeys.insert(current.visualKey)
        }
        if let previous = slots[index].previousCard {
            excludedIDs.insert(previous.id)
            excludedVisualKeys.insert(previous.visualKey)
        }

        return pickCard(
            excludingIDs: excludedIDs,
            excludingVisualKeys: excludedVisualKeys
        )
    }

    private mutating func pickCard(
        excludingIDs: Set<String>,
        excludingVisualKeys: Set<String>
    ) -> AmbientCardModel? {
        guard !cards.isEmpty else { return nil }

        let strict = cards.filter {
            !excludingIDs.contains($0.id) && !excludingVisualKeys.contains($0.visualKey)
        }
        if let card = randomElement(in: strict) {
            return card
        }

        // 小卡池无法同时满足两类约束时，先保住“不是同一张卡”，最后才允许重复。
        let differentID = cards.filter { !excludingIDs.contains($0.id) }
        return randomElement(in: differentID) ?? randomElement(in: cards)
    }

    private mutating func randomElement(in candidates: [AmbientCardModel]) -> AmbientCardModel? {
        guard !candidates.isEmpty else { return nil }
        return candidates[random.nextInt(upperBound: candidates.count)]
    }

    private func neighborCards(for index: Int, in currentSlots: [Slot]) -> [AmbientCardModel] {
        guard config.columnCount > 0 else { return [] }
        var result: [AmbientCardModel] = []
        let row = index / config.columnCount
        let column = index % config.columnCount

        if column > 0, index - 1 < currentSlots.count, let left = currentSlots[index - 1].card {
            result.append(left)
        }
        if column + 1 < config.columnCount, index + 1 < currentSlots.count,
           let right = currentSlots[index + 1].card {
            result.append(right)
        }
        let upperIndex = index - config.columnCount
        if row > 0, upperIndex >= 0, upperIndex < currentSlots.count,
           let upper = currentSlots[upperIndex].card {
            result.append(upper)
        }
        let lowerIndex = index + config.columnCount
        if lowerIndex < currentSlots.count, let lower = currentSlots[lowerIndex].card {
            result.append(lower)
        }
        return result
    }

    private func result(changedSlotIDs: Set<Int>) -> AmbientAdvanceResult {
        AmbientAdvanceResult(
            snapshots: snapshots,
            changedSlotIDs: changedSlotIDs,
            nextDeadline: nextDeadline
        )
    }

    private static func uniqueCards(_ cards: [AmbientCardModel]) -> [AmbientCardModel] {
        var seen = Set<String>()
        return cards.filter { seen.insert($0.id).inserted }
    }
}

/// 标准 SplitMix64；只用于布局抽样，不承担密码学随机需求。
private struct SplitMix64: Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextInt(upperBound: Int) -> Int {
        precondition(upperBound > 0, "upperBound must be positive")
        return Int(next() % UInt64(upperBound))
    }

    private mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
