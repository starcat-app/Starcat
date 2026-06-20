//
//  GatedTagRepository.swift
//  Starcat
//
//  Pro 标签数量门控包装器。
//

import Foundation

/// 给 `TagRepositoryProtocol` 增加免费版标签数量限制。
///
/// 设计约束：
/// - 只拦截 `create(_:)`，因为 update/delete/merge 不会增加标签数量；
/// - 真正的数据读写仍交给底层 repository，避免复制 GRDB 实现；
/// - 门控放在仓储边界，确保所有 UI 入口和未来批处理入口都走同一条限制。
@MainActor
struct GatedTagRepository: TagRepositoryProtocol {
    private let base: any TagRepositoryProtocol
    private let entitlementGate: EntitlementGate

    init(base: any TagRepositoryProtocol, entitlementGate: EntitlementGate) {
        self.base = base
        self.entitlementGate = entitlementGate
    }

    func create(_ tag: Tag) async throws {
        let currentCount = try await base.fetchAll().count
        try entitlementGate.validateTagCreation(currentTagCount: currentCount)
        try await base.create(tag)
    }

    func update(_ tag: Tag) async throws {
        try await base.update(tag)
    }

    func delete(id: String) async throws {
        try await base.delete(id: id)
    }

    func merge(source: String, into target: String) async throws {
        try await base.merge(source: source, into: target)
    }

    func find(id: String) async throws -> Tag? {
        try await base.find(id: id)
    }

    func findByName(_ name: String) async throws -> Tag? {
        try await base.findByName(name)
    }

    func fetchAll() async throws -> [Tag] {
        try await base.fetchAll()
    }
}
