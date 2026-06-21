//
//  SmartCollectionRepositoryTests.swift
//  StarcatTests
//
//  用户自定义智能集合持久化与 Pro 限额门控测试。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("SmartCollectionRepository")
struct SmartCollectionRepositoryTests {

    @Test("create/fetch/find/delete 保留规则 JSON 并按 sortOrder 排序")
    func crudRoundTrip() async throws {
        let repo = try makeRepo()
        let first = try makeCollection(
            id: "first",
            name: "Swift 正在使用",
            sortOrder: 1,
            rule: SmartCollectionRule(
                scope: .language("Swift"),
                query: "database",
                searchModeRaw: SmartSearchMode.keyword.rawValue,
                statusRaw: RepoStatus.using.rawValue,
                selectedTagIDs: ["tag-a"],
                hideArchived: true,
                hideForks: false,
                sortRaw: RepoSortOption.updatedDesc.rawValue
            )
        )
        let second = try makeCollection(
            id: "second",
            name: "全部收藏",
            sortOrder: 0,
            rule: SmartCollectionRule(
                scope: .allStars,
                query: nil,
                searchModeRaw: SmartSearchMode.keyword.rawValue,
                statusRaw: nil,
                selectedTagIDs: [],
                hideArchived: false,
                hideForks: true,
                sortRaw: RepoSortOption.starredAtDesc.rawValue
            )
        )

        try await repo.create(first)
        try await repo.create(second)

        let all = try await repo.fetchAll()
        #expect(all.map(\.id) == ["second", "first"])
        #expect(all[1].rule == first.rule)

        let found = try #require(try await repo.find(id: "first"))
        #expect(found.name == "Swift 正在使用")
        #expect(found.rule?.status == .using)
        #expect(found.rule?.sortOption == .updatedDesc)

        try await repo.delete(id: "first")
        #expect(try await repo.find(id: "first") == nil)
        #expect(try await repo.count() == 1)
    }

    @Test("免费用户通过门控 repository 只能创建 4 个自定义智能集合")
    func gatedRepositoryBlocksFifthFreeCollection() async throws {
        let base = try makeRepo()
        let gate = EntitlementGate(
            entitlementProvider: SmartCollectionTestEntitlementProvider(isPro: false),
            userIDProvider: { 42 }
        )
        let gated = GatedSmartCollectionRepository(base: base, entitlementGate: gate)

        for index in 0..<EntitlementGate.freeSmartCollectionLimit {
            try await gated.create(try makeCollection(id: "free-\(index)", name: "Free \(index)", sortOrder: index))
        }

        do {
            try await gated.create(try makeCollection(id: "free-5", name: "Free 5", sortOrder: 5))
            Issue.record("免费用户第 5 个自定义智能集合应被门控拦截")
        } catch let error as EntitlementGateError {
            #expect(error == .smartCollectionLimitReached(limit: EntitlementGate.freeSmartCollectionLimit))
        }

        #expect(try await base.count() == EntitlementGate.freeSmartCollectionLimit)
    }

    @Test("删除全部自定义集合后，免费用户可再次创建")
    func gatedRepositoryAllowsCreateAfterDeleteAll() async throws {
        let base = try makeRepo()
        let gate = EntitlementGate(
            entitlementProvider: SmartCollectionTestEntitlementProvider(isPro: false),
            userIDProvider: { 42 }
        )
        let gated = GatedSmartCollectionRepository(base: base, entitlementGate: gate)

        var ids: [String] = []
        for index in 0..<EntitlementGate.freeSmartCollectionLimit {
            let id = "slot-\(index)"
            ids.append(id)
            try await gated.create(try makeCollection(id: id, name: "Slot \(index)", sortOrder: index))
        }

        for id in ids {
            try await gated.delete(id: id)
        }
        #expect(try await base.fetchAll().isEmpty)
        #expect(try await base.count() == 0)

        try await gated.create(try makeCollection(id: "after-delete", name: "After Delete", sortOrder: 0))
        #expect(try await base.count() == 1)
    }

    @Test("count 与 fetchAll 条数始终一致")
    func countMatchesFetchAll() async throws {
        let repo = try makeRepo()
        try await repo.create(try makeCollection(id: "a", name: "A", sortOrder: 0))
        try await repo.create(try makeCollection(id: "b", name: "B", sortOrder: 1))
        let fetched = try await repo.fetchAll()
        #expect(try await repo.count() == fetched.count)

        try await repo.delete(id: "a")
        #expect(try await repo.count() == 1)
        #expect(try await repo.fetchAll().count == 1)
    }

    private func makeRepo() throws -> GRDBSmartCollectionRepository {
        let db = try InMemoryDatabaseManager()
        return GRDBSmartCollectionRepository(database: db)
    }

    private func makeCollection(
        id: String,
        name: String,
        sortOrder: Int,
        rule: SmartCollectionRule? = nil
    ) throws -> UserSmartCollection {
        let snapshot = rule ?? SmartCollectionRule(
            scope: .allStars,
            query: nil,
            searchModeRaw: SmartSearchMode.keyword.rawValue,
            statusRaw: nil,
            selectedTagIDs: [],
            hideArchived: false,
            hideForks: false,
            sortRaw: RepoSortOption.starredAtDesc.rawValue
        )
        let now = "2026-06-21T00:00:00Z"
        return UserSmartCollection(
            id: id,
            name: name,
            icon: "line.3.horizontal.decrease.circle",
            color: nil,
            ruleJSON: try SmartCollectionRule.encode(snapshot),
            sortOrder: sortOrder,
            createdAt: now,
            updatedAt: now
        )
    }
}

@MainActor
private final class SmartCollectionTestEntitlementProvider: ProEntitlementProviding {
    let entitlement: ProEntitlement

    init(isPro: Bool) {
        self.entitlement = ProEntitlement(
            isActive: isPro,
            productID: isPro ? "test.pro" : nil,
            expirationDate: nil,
            verifiedAt: Date(),
            source: isPro ? .testEnvironment : .none
        )
    }
}
