//
//  GitHubDTOsTests.swift
//  StarcatTests
//
//  验证 GitHubRepoDTO / StarredRepoDTO 能正确解码 GitHub 真实响应样本。
//

import Testing
import Foundation
@testable import Starcat

@Suite("GitHub DTO 解码")
struct GitHubDTOsTests {

    /// 已发布的资料缓存没有组织字段，不能因为新增头像入口丢失整个登录快照。
    @Test("旧用户资料不含组织字段仍可解码")
    func decodeUserWithoutOrganizations() throws {
        let user = try decoder.decode(GitHubUserDTO.self, from: Data(#"{"id":42,"login":"alice"}"#.utf8))
        #expect(user.organizations == nil)
    }

    @Test("组织随资料缓存往返编码，状态更新保留组织")
    func userOrganizationsSurviveCacheRoundTripAndStatusUpdate() throws {
        var user = GitHubUserDTO(id: 42, login: "alice", name: nil, avatarUrl: nil)
        user.organizations = [GitHubOrganizationDTO(id: 101, login: "example-org", avatarUrl: nil, description: nil)]
        let cached = try JSONDecoder().decode(GitHubUserDTO.self, from: JSONEncoder().encode(user))
        #expect(cached.organizations == user.organizations)
        #expect(cached.replacingStatus(nil).organizations == user.organizations)
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    @Test("GitHubRepoDTO 解码")
    func decodeRepo() throws {
        let json = #"""
        {
            "id": 123456789,
            "name": "awesome-tool",
            "full_name": "alice/awesome-tool",
            "owner": {
                "id": 42,
                "login": "alice",
                "name": "Alice A.",
                "avatar_url": "https://avatars/alice.png"
            },
            "description": "An awesome tool",
            "language": "Swift",
            "stargazers_count": 1234,
            "forks_count": 56,
            "watchers_count": 78,
            "topics": ["ai", "swift"],
            "license": { "key": "mit", "name": "MIT License", "spdx_id": "MIT" },
            "homepage": "https://awesome.dev",
            "html_url": "https://github.com/alice/awesome-tool",
            "clone_url": "https://github.com/alice/awesome-tool.git",
            "ssh_url": "git@github.com:alice/awesome-tool.git",
            "private": false,
            "fork": false,
            "archived": false,
            "pushed_at": "2026-05-29T10:00:00Z",
            "created_at": "2024-01-01T00:00:00Z",
            "updated_at": "2026-05-29T10:00:00Z"
        }
        """#.data(using: .utf8)!

        let dto = try decoder.decode(GitHubRepoDTO.self, from: json)
        #expect(dto.id == 123456789)
        #expect(dto.fullName == "alice/awesome-tool")
        #expect(dto.owner.login == "alice")
        #expect(dto.stargazersCount == 1234)
        #expect(dto.topics == ["ai", "swift"])
        #expect(dto.isPrivate == false)
        #expect(dto.license?.spdxId == "MIT")
    }

    @Test("StarredRepoDTO 解码（带 starred_at wrapper）")
    func decodeStarred() throws {
        let json = #"""
        {
            "starred_at": "2026-05-01T08:00:00Z",
            "repo": {
                "id": 100,
                "name": "x",
                "full_name": "u/x",
                "owner": { "id": 1, "login": "u" },
                "language": null,
                "stargazers_count": 0,
                "forks_count": 0,
                "watchers_count": 0,
                "html_url": "https://github.com/u/x",
                "private": false,
                "fork": false,
                "archived": false
            }
        }
        """#.data(using: .utf8)!

        let dto = try decoder.decode(StarredRepoDTO.self, from: json)
        #expect(dto.starredAt == "2026-05-01T08:00:00Z")
        #expect(dto.repo.id == 100)
        #expect(dto.repo.language == nil)
    }

    // MARK: - SEARCH-RICH 2026-06-14 新增字段解码

    /// `/search/repositories` items 数组中单条仓库的真实结构（截取后）含
    /// `open_issues_count` / `default_branch` / `disabled` / `is_template` / `score`
    /// 5 个新字段。验证 DTO 能正确解码所有字段（含 `score` 的 Double 类型）。
    @Test("GitHubRepoDTO 解码 SEARCH-RICH 5 个新字段")
    func decodeSearchRichFields() throws {
        let json = #"""
        {
            "id": 31792824,
            "name": "skillsjars",
            "full_name": "skillsjars/skillsjars",
            "owner": { "id": 12345, "login": "skillsjars" },
            "description": null,
            "language": "Scala",
            "stargazers_count": 18,
            "forks_count": 2,
            "watchers_count": 18,
            "topics": ["scala"],
            "license": null,
            "homepage": null,
            "html_url": "https://github.com/skillsjars/skillsjars",
            "clone_url": "https://github.com/skillsjars/skillsjars.git",
            "ssh_url": "git@github.com:skillsjars/skillsjars.git",
            "private": false,
            "fork": false,
            "archived": false,
            "open_issues_count": 5,
            "default_branch": "master",
            "disabled": false,
            "is_template": true,
            "score": 1.0
        }
        """#.data(using: .utf8)!

        let dto = try decoder.decode(GitHubRepoDTO.self, from: json)
        #expect(dto.openIssuesCount == 5)
        #expect(dto.defaultBranch == "master")
        #expect(dto.disabled == false)
        #expect(dto.isTemplate == true)
        #expect(dto.score == 1.0)
    }

    @Test("GitHubRepoDTO 解码 fork parent")
    func decodeForkParent() throws {
        let json = #"""
        {
            "id": 200,
            "name": "xxl-job",
            "full_name": "dong4j/xxl-job",
            "owner": { "id": 2, "login": "dong4j" },
            "stargazers_count": 1,
            "forks_count": 0,
            "watchers_count": 0,
            "html_url": "https://github.com/dong4j/xxl-job",
            "private": false,
            "fork": true,
            "archived": false,
            "default_branch": "master",
            "parent": {
                "full_name": "xuxueli/xxl-job",
                "html_url": "https://github.com/xuxueli/xxl-job",
                "default_branch": "master",
                "owner": { "id": 3, "login": "xuxueli" }
            }
        }
        """#.data(using: .utf8)!

        let dto = try decoder.decode(GitHubRepoDTO.self, from: json)
        #expect(dto.fork == true)
        #expect(dto.parent?.fullName == "xuxueli/xxl-job")
        #expect(dto.parent?.ownerLogin == "xuxueli")
        #expect(dto.parent?.repoName == "xxl-job")
        #expect(dto.parent?.defaultBranch == "master")
    }

    /// 老的 `/user/starred` 嵌套 repo 不一定带新字段（部分字段是新增 API
    /// 字段或本来就只在 `/repos/{owner}/{repo}` 端点返回）。验证全部缺失时
    /// DTO 仍解码成功，新字段全部为 nil。
    @Test("GitHubRepoDTO 缺失 SEARCH-RICH 字段时安全降级为 nil")
    func decodeWithoutSearchRichFields() throws {
        let json = #"""
        {
            "id": 100,
            "name": "x",
            "full_name": "u/x",
            "owner": { "id": 1, "login": "u" },
            "language": null,
            "stargazers_count": 0,
            "forks_count": 0,
            "watchers_count": 0,
            "html_url": "https://github.com/u/x",
            "private": false,
            "fork": false,
            "archived": false
        }
        """#.data(using: .utf8)!

        let dto = try decoder.decode(GitHubRepoDTO.self, from: json)
        #expect(dto.openIssuesCount == nil)
        #expect(dto.defaultBranch == nil)
        #expect(dto.disabled == nil)
        #expect(dto.isTemplate == nil)
        #expect(dto.score == nil)
        #expect(dto.parent == nil)
    }
}
