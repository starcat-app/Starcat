//
//  StarcatRepoCardDTOTests.swift
//  StarcatTests
//
//  覆盖 R-01「三场景共用架构」前端 DTO 解码契约的关键路径测试。
//
//  覆盖点（设计 18-三场景共用架构.md §6.1 + R-01-重构进度.md Step 2.1）：
//  1. schema_version = 1 的标准响应能解码出 envelope + 卡片数组 + trending/weekly 扩展段
//  2. schema_version > supportedSchemaVersion 时 `isSupported` 返回 false（提示前端要升级）
//  3. 卡片缺扩展段时 trending / weekly 自动为 nil（向后兼容）
//  4. 必填字段 `gh_repo_id` 缺失会抛 DecodingError（N5 决策：不允许后端返回未补全的 repo）
//  5. `toEphemeralRepo()` 字段映射符合 §6.1 + Repo 表 schema
//

import Testing
import Foundation
@testable import Starcat

@Suite("StarcatRepoCardDTO 解码（R-01 §6.1）")
struct StarcatRepoCardDTOTests {

    // MARK: - 1. 标准 schema=1 响应

    @Test("schema_version=1 标准响应：envelope + 卡片 + trending 扩展段")
    func decodeStandardEnvelopeWithTrending() throws {
        let json = #"""
        {
          "schema_version": 1,
          "data": [
            {
              "gh_repo_id": 100200300,
              "full_name": "alice/awesome",
              "owner": "alice",
              "repo": "awesome",
              "owner_avatar": "https://avatars.githubusercontent.com/u/1?v=4",
              "description": "An awesome tool",
              "language": "Swift",
              "stars": 1234,
              "forks": 56,
              "watchers": 12,
              "subscribers": 8,
              "topics": ["ai", "swift"],
              "homepage": "https://awesome.dev",
              "license_spdx": "MIT",
              "is_archived": false,
              "is_fork": false,
              "is_private": false,
              "default_branch": "main",
              "open_issues": 3,
              "pushed_at": "2026-06-08T12:00:00Z",
              "updated_at": "2026-06-08T12:00:00Z",
              "created_at": "2024-01-01T00:00:00Z",
              "html_url": "https://github.com/alice/awesome",
              "trending": {
                "change": 321,
                "contributors": [
                  { "avatar": "https://avatars.githubusercontent.com/u/2?v=4", "login": "bob" }
                ]
              }
            }
          ]
        }
        """#.data(using: .utf8)!

        let response = try JSONDecoder().decode(StarcatEnvelope<[StarcatRepoCardDTO]>.self, from: json)
        #expect(response.schemaVersion == 1)
        #expect(response.isSupported == true)
        #expect(response.data.count == 1)

        let card = response.data[0]
        #expect(card.ghRepoId == 100200300)
        #expect(card.fullName == "alice/awesome")
        #expect(card.owner == "alice")
        #expect(card.repo == "awesome")
        #expect(card.stars == 1234)
        #expect(card.forks == 56)
        #expect(card.topics == ["ai", "swift"])
        #expect(card.licenseSpdx == "MIT")
        #expect(card.isArchived == false)
        #expect(card.weekly == nil)
        #expect(card.trending?.change == 321)
        #expect(card.trending?.contributors.count == 1)
        #expect(card.trending?.contributors[0].login == "bob")
    }

    @Test("schema_version=1 + weekly 扩展段")
    func decodeWeeklyEnvelope() throws {
        let json = #"""
        {
          "schema_version": 1,
          "data": [
            {
              "gh_repo_id": 9999,
              "full_name": "ruan/weekly",
              "owner": "ruan",
              "repo": "weekly",
              "stars": 50000,
              "forks": 5000,
              "watchers": 0,
              "subscribers": 0,
              "topics": [],
              "is_archived": false,
              "is_fork": false,
              "is_private": false,
              "open_issues": 0,
              "weekly": {
                "first_issue": 399,
                "issue_url": "https://github.com/ruanyf/weekly/blob/master/docs/issue-399.md"
              }
            }
          ]
        }
        """#.data(using: .utf8)!

        let response = try JSONDecoder().decode(StarcatEnvelope<[StarcatRepoCardDTO]>.self, from: json)
        let card = response.data[0]
        #expect(card.weekly?.firstIssue == 399)
        #expect(card.weekly?.issueUrl.absoluteString.contains("issue-399.md") == true)
        #expect(card.trending == nil)
    }

    // MARK: - 2. schema_version 兼容性

    @Test("未来 schema_version=2：解码不抛错，但 isSupported 返回 false")
    func futureSchemaVersionUnsupported() throws {
        let json = #"""
        {
          "schema_version": 2,
          "data": []
        }
        """#.data(using: .utf8)!

        let response = try JSONDecoder().decode(StarcatEnvelope<[StarcatRepoCardDTO]>.self, from: json)
        #expect(response.schemaVersion == 2)
        // R-01 客户端 supportedSchemaVersion = 1，遇到 2 应认为不支持但仍能解码（向后兼容）。
        #expect(response.isSupported == false)
        #expect(response.data.isEmpty)
    }

    // MARK: - 3. 缺扩展段（向后兼容）

    @Test("缺 trending / weekly 扩展段：两者均 nil")
    func decodeWithoutExtensions() throws {
        let json = #"""
        {
          "schema_version": 1,
          "data": [
            {
              "gh_repo_id": 1,
              "full_name": "a/b",
              "owner": "a",
              "repo": "b",
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
          ]
        }
        """#.data(using: .utf8)!

        let response = try JSONDecoder().decode(StarcatEnvelope<[StarcatRepoCardDTO]>.self, from: json)
        let card = response.data[0]
        #expect(card.trending == nil)
        #expect(card.weekly == nil)
        #expect(card.topics.isEmpty)
        #expect(card.description == nil)
    }

    // MARK: - 4. 必填字段缺失抛错（N5 契约）

    @Test("gh_repo_id 缺失 → 抛 DecodingError（N5 契约）")
    func missingGhRepoIdThrows() {
        let json = #"""
        {
          "schema_version": 1,
          "data": [
            {
              "full_name": "a/b",
              "owner": "a",
              "repo": "b",
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
          ]
        }
        """#.data(using: .utf8)!

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(StarcatEnvelope<[StarcatRepoCardDTO]>.self, from: json)
        }
    }

    @Test("schema_version 缺失 → 抛 DecodingError")
    func missingSchemaVersionThrows() {
        let json = #"""
        { "data": [] }
        """#.data(using: .utf8)!

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(StarcatEnvelope<[StarcatRepoCardDTO]>.self, from: json)
        }
    }

    // MARK: - 5. toEphemeralRepo 字段映射

    @Test("toEphemeralRepo: 字段映射正确，isStarred 永远 false，topics 序列化为 JSON 字符串")
    func ephemeralRepoMapping() {
        let dto = StarcatRepoCardDTO(
            ghRepoId: 42,
            fullName: "alice/foo",
            owner: "alice",
            repo: "foo",
            ownerAvatar: URL(string: "https://avatars.githubusercontent.com/u/1?v=4"),
            description: "desc",
            language: "Rust",
            stars: 100,
            forks: 10,
            watchers: 5,
            subscribers: 3,
            topics: ["rust", "cli"],
            homepage: URL(string: "https://foo.dev"),
            licenseSpdx: "Apache-2.0",
            isArchived: true,
            isFork: false,
            isPrivate: false,
            defaultBranch: "main",
            openIssues: 1,
            pushedAt: "2026-06-08T12:00:00Z",
            updatedAt: "2026-06-08T12:00:00Z",
            createdAt: "2024-01-01T00:00:00Z",
            htmlUrl: URL(string: "https://github.com/alice/foo")
        )

        let repo = dto.toEphemeralRepo()
        #expect(repo.id == 42)
        #expect(repo.owner == "alice")
        #expect(repo.name == "foo")
        #expect(repo.fullName == "alice/foo")
        #expect(repo.starsCount == 100)
        #expect(repo.forksCount == 10)
        #expect(repo.watchersCount == 5)
        #expect(repo.license == "Apache-2.0")
        #expect(repo.isArchived == true)
        // ephemeral Repo 不持有 star 状态（DTO 来源不知道当前用户）
        #expect(repo.isStarred == false)
        #expect(repo.cachedAt == nil)
        #expect(repo.starredAt == nil)
        #expect(repo.cloneUrl == nil)
        #expect(repo.sshUrl == nil)
        // topics 应序列化为 JSON 字符串
        #expect(repo.topicsArray == ["rust", "cli"])
        #expect(repo.htmlUrl == "https://github.com/alice/foo")
    }

    @Test("toEphemeralRepo: 缺 html_url 时 fallback 到 GitHubURLs.repo")
    func ephemeralRepoFallbackHtmlUrl() {
        let dto = StarcatRepoCardDTO(
            ghRepoId: 1,
            fullName: "a/b",
            owner: "a",
            repo: "b",
            htmlUrl: nil
        )
        let repo = dto.toEphemeralRepo()
        // GitHubURLs.repo(owner:"a", repo:"b") -> "https://github.com/a/b"
        #expect(repo.htmlUrl == "https://github.com/a/b")
    }

    @Test("toEphemeralRepo: 空 topics → topics 字段为 nil")
    func ephemeralRepoEmptyTopics() {
        let dto = StarcatRepoCardDTO(
            ghRepoId: 1,
            fullName: "a/b",
            owner: "a",
            repo: "b",
            topics: []
        )
        let repo = dto.toEphemeralRepo()
        #expect(repo.topics == nil)
        #expect(repo.topicsArray.isEmpty)
    }
}
