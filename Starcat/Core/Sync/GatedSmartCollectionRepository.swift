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
        try validateRule(collection)
        // 与 Tag 门控一致：以 fetchAll 可见集合为准，不用裸 fetchCount。
        let currentCount = try await base.fetchAll().count
        try entitlementGate.validateSmartCollectionCreation(currentCount: currentCount)
        try await base.create(collection)
    }

    func update(_ collection: UserSmartCollection) async throws {
        // 修改名称/图标不重新限制已保存的高级规则；只有规则发生变化才执行原规则校验。
        if try await base.find(id: collection.id)?.rule != collection.rule {
            try validateRule(collection)
        }
        try await base.update(collection)
    }

    func delete(id: String) async throws {
        try await base.delete(id: id)
    }

    /// 高级规则是 App 领域约束，不能只靠编辑 Sheet 判断，否则无窗口调用会绕过同一规则。
    private func validateRule(_ collection: UserSmartCollection) throws {
        if collection.rule?.usesProPredicates == true {
            try entitlementGate.requirePro(.repoHealth)
        }
    }
}
