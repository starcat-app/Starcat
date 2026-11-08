//
//  ActivityCategoryCountServiceTests.swift
//  StarcatTests
//
//  验证侧栏计数同步恢复、局部刷新和账号隔离，避免把未知状态显示成零。
//

import Foundation
import Testing
@testable import Starcat

/// 每个用例独享 UserDefaults 域，既验证真实持久化，也不影响本机用户设置。
@MainActor
@Suite("Activity sidebar count cache")
struct ActivityCategoryCountServiceTests {
    /// 在同一持久化域内模拟服务重建与账号切换，结束后删除测试数据。
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "ActivityCategoryCountServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test("同账号重建服务后同步恢复数量，无需等待读库")
    func restoresCountsSynchronously() throws {
        try withDefaults { defaults in
            let service = ActivityCategoryCountService(defaults: defaults, accountID: 101)
            service.applyLocalCounts(
                [.all: 150, .following: 30, .announcement: 40],
                scopeRevision: service.scopeRevision
            )
            service.applyUndoStarCount(8, scopeRevision: service.scopeRevision)

            let restored = ActivityCategoryCountService(defaults: defaults, accountID: 101)
            #expect(restored.count(for: .all) == 150)
            #expect(restored.count(for: .following) == 30)
            #expect(restored.count(for: .announcement) == 40)
            #expect(restored.count(for: .undoStar) == 8)
            #expect(restored.count(for: .release) == nil)
        }
    }

    @Test("局部计数更新保留其它缓存，真实零持久化后可恢复")
    func mergesPartialCountsAndPersistsZero() throws {
        try withDefaults { defaults in
            let service = ActivityCategoryCountService(defaults: defaults, accountID: 101)
            service.applyLocalCounts(
                [.following: 30, .announcement: 40], scopeRevision: service.scopeRevision
            )
            service.applyLocalCounts([.following: 0], scopeRevision: service.scopeRevision)

            let restored = ActivityCategoryCountService(defaults: defaults, accountID: 101)
            #expect(restored.count(for: .following) == 0)
            #expect(restored.count(for: .announcement) == 40)
            #expect(restored.count(for: .star) == nil)
        }
    }

    @Test("账号与匿名缓存隔离，切回立即恢复且拒绝旧代际写入")
    func isolatesAccountsAndRejectsLateResults() throws {
        try withDefaults { defaults in
            let service = ActivityCategoryCountService(defaults: defaults, accountID: 101)
            let accountARevision = service.scopeRevision
            service.applyLocalCounts([.following: 30], scopeRevision: accountARevision)
            service.applyUndoStarCount(8, scopeRevision: accountARevision)
            service.prepareForAccountChange()
            // reopen 挂起期间，即便使用当前代际也不得发布或落盘。
            service.applyLocalCounts([.following: 999], scopeRevision: service.scopeRevision)
            #expect(service.count(for: .following) == nil)
            service.activate(accountID: 202)
            #expect(service.count(for: .following) == nil)
            #expect(service.count(for: .undoStar) == nil)
            service.applyLocalCounts([.following: 7], scopeRevision: service.scopeRevision)
            service.applyLocalCounts([.following: 999], scopeRevision: accountARevision)
            service.applyUndoStarCount(999, scopeRevision: accountARevision)
            #expect(service.count(for: .following) == 7)
            #expect(service.count(for: .undoStar) == nil)

            service.prepareForAccountChange()
            service.activate(accountID: nil)
            #expect(service.count(for: .following) == nil)
            service.applyLocalCounts([.following: 0], scopeRevision: service.scopeRevision)
            service.prepareForAccountChange()
            service.activate(accountID: 101)
            #expect(service.count(for: .following) == 30)
            #expect(service.count(for: .undoStar) == 8)
            let accountB = ActivityCategoryCountService(defaults: defaults, accountID: 202)
            #expect(accountB.count(for: .following) == 7)
            let anonymous = ActivityCategoryCountService(defaults: defaults)
            #expect(anonymous.count(for: .following) == 0)
        }
    }

    @Test("数据库切换失败后恢复旧缓存，原页面仍可发布计数")
    func failedAccountChangeKeepsOriginalScope() throws {
        try withDefaults { defaults in
            let service = ActivityCategoryCountService(defaults: defaults, accountID: 101)
            let revision = service.scopeRevision
            service.applyLocalCounts([.following: 30], scopeRevision: revision)
            service.prepareForAccountChange()
            service.cancelAccountChange()
            #expect(service.count(for: .following) == 30)
            service.applyLocalCounts([.following: 31], scopeRevision: revision)
            #expect(service.count(for: .following) == 31)
        }
    }
}
