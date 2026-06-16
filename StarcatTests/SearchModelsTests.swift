//
//  SearchModelsTests.swift
//  StarcatTests
//
//  搜索领域模型的纯逻辑回归测试。
//
//  历史记录（SearchHistory + GRDBSearchHistoryRepository）的测试已迁到
//  `SearchHistoryRepositoryTests.swift`，原 UserDefaults 版本的
//  `SearchHistoryStoreTests` 在 2026-06-14 持久化升级到 GRDB 后整体废弃。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Search Models")
struct SearchModelsTests {
    @Test("RepoIdentity 有双 ID 时优先按 GitHub ID 判断")
    func identityUsesGitHubID() {
        let first = RepoIdentity(ghRepoID: 42, owner: "old", name: "name")
        let renamed = RepoIdentity(ghRepoID: 42, owner: "new", name: "name")
        #expect(first == renamed)
    }

    @Test("RepoIdentity 缺 ID 时按 owner/name 大小写不敏感判断")
    func identityFallsBackToFullName() {
        let first = RepoIdentity(ghRepoID: nil, owner: "OpenAI", name: "Codex")
        let second = RepoIdentity(ghRepoID: nil, owner: "openai", name: "codex")
        #expect(first == second)
        #expect(first.hashValue == second.hashValue)
    }

    @Test("SearchRequest 规范化 query、page 与 perPage")
    func requestNormalizesValues() {
        let request = SearchRequest(query: "  swift  ", page: 0, perPage: 999)
        #expect(request.query == "swift")
        #expect(request.page == 1)
        #expect(request.perPage == 100)
    }

    // MARK: - SEARCH-RICH 2026-06-14

    /// `RemoteRepoExtras.empty` 是默认占位，用作非 GitHub 来源的候选 fallback。
    /// `hasAnyVisibleBadge` 必须严格区分「未填」与「true」：disabled = false 不算
    /// 信号（仓库正常在用），不应触发徽章渲染。
    @Test("RemoteRepoExtras.hasAnyVisibleBadge 仅在 disabled/isTemplate == true 时为真")
    func remoteRepoExtrasBadgeVisibility() {
        #expect(RemoteRepoExtras.empty.hasAnyVisibleBadge == false)
        #expect(RemoteRepoExtras(disabled: false, isTemplate: false, score: 0.9)
            .hasAnyVisibleBadge == false)
        #expect(RemoteRepoExtras(disabled: true, isTemplate: nil, score: nil)
            .hasAnyVisibleBadge == true)
        #expect(RemoteRepoExtras(disabled: nil, isTemplate: true, score: nil)
            .hasAnyVisibleBadge == true)
    }

    /// `RepositoryCandidate.remoteExtras` 默认值是 `.empty` —— 让搜索 Coordinator /
    /// LocalKeywordSearchProvider 等不产生额外字段的来源构造候选时零负担。
    @Test("RepositoryCandidate.remoteExtras 默认 .empty")
    func repositoryCandidateExtrasDefaultsToEmpty() {
        let card = RepoCardViewData(
            ghRepoId: 1, fullName: "a/b", owner: "a", repo: "b",
            avatarURL: nil, description: nil, language: nil,
            starsCount: 0, forksCount: 0,
            isArchived: false, isFork: false, isPrivate: false,
            isStarred: false, badge: nil,
            weeklySources: [], weeklySourceLabel: nil,
            inlineMetadata: nil, readStatus: nil,
            openSSFScore: nil
        )
        let candidate = RepositoryCandidate(
            identity: RepoIdentity(ghRepoID: 1, owner: "a", name: "b"),
            card: card,
            sources: [.localKeyword],
            localRepo: nil,
            remoteRepo: nil,
            semanticScore: nil
        )
        #expect(candidate.remoteExtras == .empty)
    }

    /// 验证 `GRDBRepoRepository.repoFromDTO` 把 DTO 的 `default_branch` /
    /// `open_issues_count` / `owner.avatar_url` 接通进 `Repo` 模型。这些字段过去
    /// 长期对所有同步入库 repo 都为 nil，搜索弹窗信息密度增强后必须保证 stars
    /// 同步路径也搭车回填。
    @Test("repoFromDTO 接通 SEARCH-RICH 三个字段进 Repo")
    func repoFromDTOMapsSearchRichFieldsToRepo() {
        let owner = GitHubUserDTO(
            id: 1, login: "tester",
            name: nil, avatarUrl: "https://avatars.example/tester.png",
            publicRepos: nil, followers: nil, following: nil,
            bio: nil, company: nil, location: nil, email: nil,
            blog: nil, twitterUsername: nil, htmlUrl: nil
        )
        let dto = GitHubRepoDTO(
            id: 7, name: "r", fullName: "tester/r", owner: owner,
            description: nil, language: nil,
            stargazersCount: 0, forksCount: 0, watchersCount: 0,
            topics: nil, license: nil, homepage: nil,
            htmlUrl: "https://github.com/tester/r",
            cloneUrl: nil, sshUrl: nil,
            isPrivate: false, fork: false, archived: false,
            pushedAt: nil, createdAt: nil, updatedAt: nil,
            openIssuesCount: 12,
            defaultBranch: "main",
            disabled: nil,    // 不入 Repo 模型，本测试不验
            isTemplate: nil,  // 不入 Repo 模型，本测试不验
            score: nil
        )
        let repo = GRDBRepoRepository.repoFromDTO(
            dto, starredAt: nil, cachedAt: "2026-06-14T00:00:00Z", isStarred: false
        )
        #expect(repo.openIssuesCount == 12)
        #expect(repo.defaultBranch == "main")
        #expect(repo.ownerAvatar == "https://avatars.example/tester.png")
        // subscribersCount 不在 search / starred 端点返回，应保持 nil
        #expect(repo.subscribersCount == nil)
    }
}
