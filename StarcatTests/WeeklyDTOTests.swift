//
//  WeeklyDTOTests.swift
//  StarcatTests
//
//  R-01 v1.2 后：验证 envelope 化的 weekly 响应能正确解码到 `StarcatRepoCardDTO + WeeklyExtension`，
//  并能转换成 UI 消费的 `WeeklyProject` 领域模型。
//
//  关键约束：
//  - 后端响应顶层走 `StarcatEnvelope<[StarcatRepoCardDTO]>`（schema_version + data + meta）
//  - 周刊场景独有字段（`first_issue` / `issue_url`）放在 `weekly` 扩展段下
//  - description / language / weekly 段都可缺；缺字段时默认值要落到 UI 友好的回退值
//

import Testing
import Foundation
@testable import Starcat

@Suite("Weekly Envelope 解码")
struct WeeklyDTOTests {

    private var decoder: JSONDecoder { JSONDecoder() }

    @Test("完整 envelope 响应解码到 WeeklyProject")
    func decodeFullEnvelope() throws {
        let json = #"""
        {
          "schema_version": 1,
          "data": [
            {
              "gh_repo_id": 100001,
              "full_name": "alice/awesome-tool",
              "owner": "alice",
              "repo": "awesome-tool",
              "description": "An awesome tool",
              "language": "Go",
              "stars": 1234,
              "forks": 100,
              "watchers": 1234,
              "subscribers": 50,
              "topics": [],
              "is_archived": false,
              "is_fork": false,
              "is_private": false,
              "open_issues": 5,
              "html_url": "https://github.com/alice/awesome-tool",
              "weekly": {
                "first_issue": 399,
                "issue_url": "https://github.com/ruanyf/weekly/blob/master/docs/issue-399.md"
              }
            }
          ],
          "meta": {
            "page": 1,
            "page_size": 20,
            "total": 1
          }
        }
        """#

        let data = try #require(json.data(using: .utf8))
        let envelope = try decoder.decode(StarcatEnvelope<[StarcatRepoCardDTO]>.self, from: data)

        #expect(envelope.schemaVersion == 1)
        #expect(envelope.isSupported == true)
        #expect(envelope.data.count == 1)
        #expect(envelope.meta?.total == 1)
        #expect(envelope.meta?.page == 1)
        #expect(envelope.meta?.pageSize == 20)

        let project = WeeklyProject(card: envelope.data[0])
        #expect(project.owner == "alice")
        #expect(project.name == "awesome-tool")
        #expect(project.fullName == "alice/awesome-tool")
        #expect(project.stars == 1234)
        #expect(project.language == "Go")
        #expect(project.firstIssue == 399)
        #expect(project.url.absoluteString == "https://github.com/alice/awesome-tool")
        #expect(project.issueURL?.absoluteString == "https://github.com/ruanyf/weekly/blob/master/docs/issue-399.md")
    }

    @Test("description / language / weekly 缺失时使用回退")
    func decodeWithMissingOptionalFields() throws {
        // weekly 扩展段缺失（弱关联场景：项目暂未在周刊收录但仍在卡片列表里出现，
        // 后端返回时会省略 weekly 段；前端应能优雅退化）。
        let json = #"""
        {
          "schema_version": 1,
          "data": [
            {
              "gh_repo_id": 100002,
              "full_name": "bob/tiny",
              "owner": "bob",
              "repo": "tiny",
              "stars": 0,
              "forks": 0,
              "watchers": 0,
              "subscribers": 0,
              "topics": [],
              "is_archived": false,
              "is_fork": false,
              "is_private": false,
              "open_issues": 0
            }
          ],
          "meta": {
            "page": 1,
            "page_size": 20,
            "total": 1
          }
        }
        """#

        let data = try #require(json.data(using: .utf8))
        let envelope = try decoder.decode(StarcatEnvelope<[StarcatRepoCardDTO]>.self, from: data)
        let project = WeeklyProject(card: envelope.data[0])

        #expect(project.description == nil)
        #expect(project.language == nil)
        #expect(project.firstIssue == 0)
        #expect(project.issueURL == nil, "缺 weekly 段时 issueURL 应为 nil")
    }

    @Test("空 data 数组不报错")
    func decodeEmptyEnvelope() throws {
        let json = #"""
        {
          "schema_version": 1,
          "data": [],
          "meta": { "page": 1, "page_size": 20, "total": 0 }
        }
        """#
        let data = try #require(json.data(using: .utf8))
        let envelope = try decoder.decode(StarcatEnvelope<[StarcatRepoCardDTO]>.self, from: data)
        #expect(envelope.data.isEmpty)
        #expect(envelope.meta?.total == 0)
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
