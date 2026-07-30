//
//  WidgetRepositoryEntityQueryTests.swift
//  StarcatTests
//
//  Focus Widget 动态配置实体映射测试。
//

import Foundation
import Testing
@testable import Starcat

struct WidgetRepositoryEntityQueryTests {

    @Test("Focus 仓库实体保持快照顺序并按仓库 ID 去重")
    func mapsRepositoriesInStableOrderWithoutDuplicates() {
        let repositories = [
            makeRepository(id: 2, owner: "second", name: "two"),
            makeRepository(id: 2, owner: "duplicate", name: "ignored"),
            makeRepository(id: 1, owner: "first", name: "one"),
        ]

        let entities = WidgetRepositoryEntityQuery.entities(from: repositories)

        #expect(entities.map(\.id) == ["2", "1"])
        #expect(entities.map(\.repositoryID) == [2, 1])
        #expect(entities.map(\.owner) == ["second", "first"])
        #expect(entities.map(\.name) == ["two", "one"])
    }

    private func makeRepository(id: Int64, owner: String, name: String) -> WidgetRepository {
        WidgetRepository(
            id: id,
            owner: owner,
            name: name,
            description: nil,
            language: nil,
            starsCount: 0,
            tags: [],
            status: nil,
            focusSource: .pinned,
            avatarFileName: nil,
            openURL: URL(string: "starcat://repo/\(owner)/\(name)?v=1&rid=\(id)")!
        )
    }
}
