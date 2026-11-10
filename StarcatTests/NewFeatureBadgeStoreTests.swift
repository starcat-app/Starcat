//
//  NewFeatureBadgeStoreTests.swift
//  Starcat
//
//  新功能标识状态的独立持久化测试。
//

import Foundation
import Testing
@testable import Starcat

@Suite("New feature badge store")
@MainActor
struct NewFeatureBadgeStoreTests {

    @Test("四个入口初始可见，点击后只消除当前入口并持久化")
    func badgeIsIndependentAndPersistent() throws {
        let suite = "NewFeatureBadgeStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = NewFeatureBadgeStore(defaults: defaults)
        #expect(NewFeatureBadgeStore.Feature.allCases.allSatisfy { store.shouldShowBadge(for: $0) })

        store.markVisited(.followersGraph)
        #expect(!store.shouldShowBadge(for: .followersGraph))
        #expect(store.shouldShowBadge(for: .followingGraph))
        #expect(store.shouldShowBadge(for: .dailyRadar))
        #expect(store.shouldShowBadge(for: .linuxDo))

        // 重复标记不产生额外写入；新实例必须能从 UserDefaults 恢复已点击状态。
        store.markVisited(.followersGraph)
        let restoredStore = NewFeatureBadgeStore(defaults: defaults)
        #expect(!restoredStore.shouldShowBadge(for: .followersGraph))
        #expect(restoredStore.shouldShowBadge(for: .followingGraph))
    }
}
