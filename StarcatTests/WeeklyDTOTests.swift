//
//  WeeklyDTOTests.swift
//  StarcatTests
//
//  验证 WeeklyProjectListDTO / WeeklyProjectDTO 能正确解码 starcat-weekly-api
//  约定的响应格式，并能转换成 UI 消费的 `WeeklyProject` 领域模型。
//
//  关键约束：
//  - DTO 不开 `.convertFromSnakeCase`，所有 snake_case 字段都通过 CodingKeys 显式映射；
//    本测试确保即便后端返回严格 snake_case，仍能正确解出 firstIssue / issueUrl。
//  - description / language 可缺；缺字段时默认值要落到 UI 友好的回退值。
//

import Testing
import Foundation
@testable import Starcat

@Suite("Weekly DTO 解码")
struct WeeklyDTOTests {

    private var decoder: JSONDecoder { JSONDecoder() }

    @Test("完整响应解码到 WeeklyProject")
    func decodeFullList() throws {
        let json = #"""
        {
          "items": [
            {
              "owner": "alice",
              "repo": "awesome-tool",
              "url": "https://github.com/alice/awesome-tool",
              "description": "An awesome tool",
              "stars": 1234,
              "language": "Go",
              "first_issue": 399,
              "issue_url": "https://github.com/ruanyf/weekly/blob/master/docs/issue-399.md"
            }
          ],
          "total": 1,
          "page": 1,
          "page_size": 20
        }
        """#

        let data = try #require(json.data(using: .utf8))
        let dto = try decoder.decode(WeeklyProjectListDTO.self, from: data)

        #expect(dto.items.count == 1)
        #expect(dto.total == 1)
        #expect(dto.page == 1)
        #expect(dto.pageSize == 20)

        let project = WeeklyProject(dto: dto.items[0])
        #expect(project.owner == "alice")
        #expect(project.name == "awesome-tool")
        #expect(project.fullName == "alice/awesome-tool")
        #expect(project.stars == 1234)
        #expect(project.language == "Go")
        #expect(project.firstIssue == 399)
        #expect(project.url.absoluteString == "https://github.com/alice/awesome-tool")
        #expect(project.issueURL?.absoluteString == "https://github.com/ruanyf/weekly/blob/master/docs/issue-399.md")
    }

    @Test("description / language / issue_url 缺失时使用回退")
    func decodeWithMissingOptionalFields() throws {
        let json = #"""
        {
          "items": [
            {
              "owner": "bob",
              "repo": "tiny",
              "url": "https://github.com/bob/tiny",
              "stars": 0,
              "first_issue": 0,
              "issue_url": ""
            }
          ],
          "total": 1,
          "page": 1,
          "page_size": 20
        }
        """#

        let data = try #require(json.data(using: .utf8))
        let dto = try decoder.decode(WeeklyProjectListDTO.self, from: data)
        let project = WeeklyProject(dto: dto.items[0])

        #expect(project.description == nil)
        #expect(project.language == nil)
        #expect(project.firstIssue == 0)
        #expect(project.issueURL == nil, "issue_url 空串时不应该构造出 URL")
    }

    @Test("空 items 不报错")
    func decodeEmptyList() throws {
        let json = #"""
        { "items": [], "total": 0, "page": 1, "page_size": 20 }
        """#
        let data = try #require(json.data(using: .utf8))
        let dto = try decoder.decode(WeeklyProjectListDTO.self, from: data)
        #expect(dto.items.isEmpty)
        #expect(dto.total == 0)
    }
}

@Suite("WeeklyProjectListResult.hasMore 推算")
struct WeeklyProjectListResultTests {

    @Test("还有下一页时 hasMore = true")
    func hasMoreWhenPagesRemain() {
        let result = WeeklyProjectListResult(items: [], total: 100, page: 1, pageSize: 20)
        #expect(result.hasMore == true)
    }

    @Test("最后一页时 hasMore = false")
    func noMoreOnLastPage() {
        let result = WeeklyProjectListResult(items: [], total: 100, page: 5, pageSize: 20)
        #expect(result.hasMore == false)
    }

    @Test("total 不足一页时 hasMore = false")
    func noMoreWhenLessThanOnePage() {
        let result = WeeklyProjectListResult(items: [], total: 5, page: 1, pageSize: 20)
        #expect(result.hasMore == false)
    }

    @Test("pageSize 0 时 hasMore = false 兜底")
    func noMoreWhenPageSizeZero() {
        let result = WeeklyProjectListResult(items: [], total: 5, page: 1, pageSize: 0)
        #expect(result.hasMore == false)
    }
}
