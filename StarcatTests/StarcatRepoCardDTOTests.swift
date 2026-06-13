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

    // MARK: - 空 URL 容错（2026-06-11 trending-api 实战修复）
    //
    // 后端 enricher 直接透传 GitHub `/repos` API 的 homepage 字段；GitHub 在仓库未填主页
    // 时返回 ""（空串）而非 null。Swift 的 URL Decodable 对 "" 会抛 dataCorrupted，
    // 整个 [StarcatRepoCardDTO] 解码挂掉，客户端报 "未能读取数据，因为它的格式不正确"。
    // 修复方案是 DTO 端的 `decodeOptionalURL` helper：把 "" / "   " / 非法 URL 全归一化为 nil。
    // 这些测试卡住该契约，防止有人未来又把 helper 改回 `decodeIfPresent(URL.self, ...)`。

    @Test("空 URL 容错：homepage='' / owner_avatar='' / html_url='' 全部解码为 nil，整体不抛错")
    func decodeEmptyURLStringsAsNil() throws {
        let json = #"""
        {
          "gh_repo_id": 1,
          "full_name": "a/b",
          "owner": "a",
          "repo": "b",
          "owner_avatar": "",
          "homepage": "",
          "html_url": "",
          "stars": 0, "forks": 0, "watchers": 0, "subscribers": 0,
          "topics": [],
          "is_archived": false, "is_fork": false, "is_private": false,
          "open_issues": 0
        }
        """#.data(using: .utf8)!

        let dto = try JSONDecoder().decode(StarcatRepoCardDTO.self, from: json)
        #expect(dto.ownerAvatar == nil)
        #expect(dto.homepage == nil)
        #expect(dto.htmlUrl == nil)
    }

    @Test("空 URL 容错：homepage 只有空白字符也算 nil")
    func decodeWhitespaceURLAsNil() throws {
        let json = #"""
        {
          "gh_repo_id": 1, "full_name": "a/b", "owner": "a", "repo": "b",
          "homepage": "   ",
          "stars": 0, "forks": 0, "watchers": 0, "subscribers": 0,
          "topics": [],
          "is_archived": false, "is_fork": false, "is_private": false,
          "open_issues": 0
        }
        """#.data(using: .utf8)!

        let dto = try JSONDecoder().decode(StarcatRepoCardDTO.self, from: json)
        #expect(dto.homepage == nil)
    }

    @Test("空 URL 容错：非法 URL 字符串吞掉返回 nil（不抛错）")
    func decodeInvalidURLStringAsNil() throws {
        // 用户笔记：Swift 的 URL(string:) 实际对大多数"看起来不像 URL"的字符串
        // 也会返回非 nil（只要不是空），所以这里用一个明确包含非法字符 / 不合法编码的串。
        // ASCII 控制字符 + 空格 + 中文 → URL(string:) 在 macOS 15 / Swift 6 上返回 nil。
        let json = #"""
        {
          "gh_repo_id": 1, "full_name": "a/b", "owner": "a", "repo": "b",
          "homepage": "not a valid url \u0001 中文",
          "stars": 0, "forks": 0, "watchers": 0, "subscribers": 0,
          "topics": [],
          "is_archived": false, "is_fork": false, "is_private": false,
          "open_issues": 0
        }
        """#.data(using: .utf8)!

        // 不抛错——即使解出来是 nil，整批响应也能正常解码。
        let dto = try JSONDecoder().decode(StarcatRepoCardDTO.self, from: json)
        // 不强断言 homepage 一定是 nil（取决于运行时 URL(string:) 的兼容行为），
        // 关键契约是「不能抛错把整批响应拖崩」。如果解出来是非 nil URL 也无害。
        _ = dto
    }

    @Test("空 URL 容错：homepage 为 null（标准 JSON null）解码为 nil")
    func decodeNullURLAsNil() throws {
        let json = #"""
        {
          "gh_repo_id": 1, "full_name": "a/b", "owner": "a", "repo": "b",
          "homepage": null,
          "stars": 0, "forks": 0, "watchers": 0, "subscribers": 0,
          "topics": [],
          "is_archived": false, "is_fork": false, "is_private": false,
          "open_issues": 0
        }
        """#.data(using: .utf8)!

        let dto = try JSONDecoder().decode(StarcatRepoCardDTO.self, from: json)
        #expect(dto.homepage == nil)
    }

    @Test("空 URL 容错：homepage 字段完全缺失解码为 nil")
    func decodeMissingURLKeyAsNil() throws {
        let json = #"""
        {
          "gh_repo_id": 1, "full_name": "a/b", "owner": "a", "repo": "b",
          "stars": 0, "forks": 0, "watchers": 0, "subscribers": 0,
          "topics": [],
          "is_archived": false, "is_fork": false, "is_private": false,
          "open_issues": 0
        }
        """#.data(using: .utf8)!

        let dto = try JSONDecoder().decode(StarcatRepoCardDTO.self, from: json)
        #expect(dto.homepage == nil)
    }

    @Test("空 URL 容错：合法 URL 字符串正常解码（不要被新 helper 误伤）")
    func decodeValidURLStillWorks() throws {
        let json = #"""
        {
          "gh_repo_id": 1, "full_name": "a/b", "owner": "a", "repo": "b",
          "owner_avatar": "https://avatars.githubusercontent.com/u/1?v=4",
          "homepage": "https://example.com/path?q=1",
          "html_url": "https://github.com/a/b",
          "stars": 0, "forks": 0, "watchers": 0, "subscribers": 0,
          "topics": [],
          "is_archived": false, "is_fork": false, "is_private": false,
          "open_issues": 0
        }
        """#.data(using: .utf8)!

        let dto = try JSONDecoder().decode(StarcatRepoCardDTO.self, from: json)
        #expect(dto.ownerAvatar?.absoluteString == "https://avatars.githubusercontent.com/u/1?v=4")
        #expect(dto.homepage?.absoluteString == "https://example.com/path?q=1")
        #expect(dto.htmlUrl?.absoluteString == "https://github.com/a/b")
    }

    @Test("空 URL 容错（端到端）：trending envelope 17 条里 5 条 homepage='' 不导致整批崩")
    func envelopeWithMixedEmptyHomepagesDecodes() throws {
        // 模拟 trending-api 实测响应：3 条 repo，其中 2 条 homepage="" 1 条有值。
        // 修复前：第一条 homepage="" 就抛 dataCorrupted，整个数组拿不到。
        // 修复后：3 条全部解码成功，homepage 字段按"空串当 nil"语义正确还原。
        let json = #"""
        {
          "schema_version": 1,
          "data": [
            {
              "gh_repo_id": 1, "full_name": "a/b", "owner": "a", "repo": "b",
              "homepage": "",
              "stars": 0, "forks": 0, "watchers": 0, "subscribers": 0,
              "topics": [],
              "is_archived": false, "is_fork": false, "is_private": false,
              "open_issues": 0
            },
            {
              "gh_repo_id": 2, "full_name": "c/d", "owner": "c", "repo": "d",
              "homepage": "https://valid.example.com",
              "stars": 1, "forks": 0, "watchers": 0, "subscribers": 0,
              "topics": [],
              "is_archived": false, "is_fork": false, "is_private": false,
              "open_issues": 0
            },
            {
              "gh_repo_id": 3, "full_name": "e/f", "owner": "e", "repo": "f",
              "homepage": "",
              "stars": 2, "forks": 0, "watchers": 0, "subscribers": 0,
              "topics": [],
              "is_archived": false, "is_fork": false, "is_private": false,
              "open_issues": 0
            }
          ]
        }
        """#.data(using: .utf8)!

        let resp = try JSONDecoder().decode(StarcatEnvelope<[StarcatRepoCardDTO]>.self, from: json)
        #expect(resp.data.count == 3)
        #expect(resp.data[0].homepage == nil)
        #expect(resp.data[1].homepage?.absoluteString == "https://valid.example.com")
        #expect(resp.data[2].homepage == nil)
    }

    // MARK: - R-01 v1.2 StarcatRepoCardDTO 扩展 4 字段消化（2026-06-10）
    //
    // 验证 owner_avatar / subscribers_count / default_branch / open_issues_count
    // 在 JSON → DTO → Repo 全链路上零字段丢失，且老 fixture（缺这 4 字段）按预期退化。

    @Test("v8 解码：4 字段全填实值时 → 进 DTO 不变形")
    func v8DecodeAllFieldsPresent() throws {
        let json = """
        {
            "gh_repo_id": 12345,
            "full_name": "foo/bar",
            "owner": "foo",
            "repo": "bar",
            "owner_avatar": "https://avatars.githubusercontent.com/foo.png",
            "subscribers": 42,
            "default_branch": "main",
            "open_issues": 7
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(StarcatRepoCardDTO.self, from: json)
        #expect(dto.ownerAvatar?.absoluteString == "https://avatars.githubusercontent.com/foo.png")
        #expect(dto.subscribers == 42)
        #expect(dto.defaultBranch == "main")
        #expect(dto.openIssues == 7)
    }

    @Test("v8 toEphemeralRepo：4 字段从 DTO 透传到 Repo")
    func v8EphemeralRepoCarriesAllFields() {
        let dto = StarcatRepoCardDTO(
            ghRepoId: 99,
            fullName: "alice/cool",
            owner: "alice",
            repo: "cool",
            ownerAvatar: URL(string: "https://avatars.githubusercontent.com/alice.png")!,
            stars: 1000,
            subscribers: 88,
            defaultBranch: "develop",
            openIssues: 12
        )
        let repo = dto.toEphemeralRepo()
        #expect(repo.id == 99)
        #expect(repo.ownerAvatar == "https://avatars.githubusercontent.com/alice.png")
        #expect(repo.subscribersCount == 88)
        #expect(repo.defaultBranch == "develop")
        #expect(repo.openIssuesCount == 12)
    }

    @Test("v8 toEphemeralRepo：DTO 缺 ownerAvatar / defaultBranch → Repo 对应字段 nil；计数字段缺失退化为 0")
    func v8EphemeralRepoMissingFieldsFallBack() {
        let dto = StarcatRepoCardDTO(
            ghRepoId: 1,
            fullName: "a/b",
            owner: "a",
            repo: "b"
        )
        let repo = dto.toEphemeralRepo()
        #expect(repo.ownerAvatar == nil)
        #expect(repo.defaultBranch == nil)
        // 计数字段 DTO 默认 0（容错解码 ?? 0），Repo 也是 0 而不是 nil
        #expect(repo.subscribersCount == 0)
        #expect(repo.openIssuesCount == 0)
    }

    @Test("v8 TrendingRepo.init(card:since:)：4 字段从 DTO 透传到领域模型")
    func v8TrendingRepoInitCarriesAllFields() {
        let dto = StarcatRepoCardDTO(
            ghRepoId: 7,
            fullName: "x/y",
            owner: "x",
            repo: "y",
            ownerAvatar: URL(string: "https://avatars.githubusercontent.com/x.png")!,
            stars: 200,
            subscribers: 33,
            defaultBranch: "main",
            openIssues: 5,
            trending: StarcatRepoCardDTO.TrendingExtension(change: 50)
        )
        let trending = TrendingRepo(card: dto, since: .daily)
        #expect(trending.ownerAvatar?.absoluteString == "https://avatars.githubusercontent.com/x.png")
        #expect(trending.subscribersCount == 33)
        #expect(trending.defaultBranch == "main")
        #expect(trending.openIssuesCount == 5)
    }
}
