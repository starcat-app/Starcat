//
//  GatedSmartCollectionRepository.swift
//  Starcat
//
//  自定义智能集合数量门控包装器。
//

import Foundation

@MainActor
struct GatedSmartCollectionRepository: SmartCollectionRepositoryProtocol {
    private let base: any SmartCollectionRepositoryProtocol
    private let entitlementGate: EntitlementGate

    init(base: any SmartCollectionRepositoryProtocol, entitlementGate: EntitlementGate) {
        self.base = base
        self.entitlementGate = entitlementGate
    }

    func fetchAll() async throws -> [UserSmartCollection] {
        try await base.fetchAll()
    }

    func find(id: String) async throws -> UserSmartCollection? {
        try await base.find(id: id)
    }

    func count() async throws -> Int {
        try await base.count()
    }

    func create(_ collection: UserSmartCollection) async throws {
        // 与 Tag 门控一致：以 fetchAll 可见集合为准，不用裸 fetchCount。
        let currentCount = try await base.fetchAll().count
        try entitlementGate.validateSmartCollectionCreation(currentCount: currentCount)
        try await base.create(collection)
    }

    func update(_ collection: UserSmartCollection) async throws {
        try await base.update(collection)
    }

    func delete(id: String) async throws {
        try await base.delete(id: id)
    }
}
