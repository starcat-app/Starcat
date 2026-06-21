//
//  SmartCollectionRepositoryProtocol.swift
//  Starcat
//
//  用户自定义智能集合 Repository 协议。
//

import Foundation

protocol SmartCollectionRepositoryProtocol: Sendable {
    func fetchAll() async throws -> [UserSmartCollection]
    func find(id: String) async throws -> UserSmartCollection?
    func count() async throws -> Int
    func create(_ collection: UserSmartCollection) async throws
    func update(_ collection: UserSmartCollection) async throws
    func delete(id: String) async throws
}
