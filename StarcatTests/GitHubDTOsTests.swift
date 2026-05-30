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
}
