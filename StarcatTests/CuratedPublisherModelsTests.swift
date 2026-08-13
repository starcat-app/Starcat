//
//  CuratedPublisherModelsTests.swift
//  StarcatTests
//
//  覆盖精选发布台的访问策略、地址收敛、幂等键与安全凭据 namespace。
//

import Foundation
import Testing
@testable import Starcat

@Suite("精选发布台领域模型")
struct CuratedPublisherModelsTests {
    @Test("只有维护者 GitHub 数字 ID 被允许")
    func accessPolicyUsesStableGitHubID() {
        #expect(CuratedPublisherAccessPolicy.canAccess(userID: 20_341_123))
        #expect(!CuratedPublisherAccessPolicy.canAccess(userID: 20_341_124))
        #expect(!CuratedPublisherAccessPolicy.canAccess(userID: nil))
    }

    @Test("GitHub URL 收敛为 canonical owner/repo")
    func parsesGitHubURLs() {
        let address = GitHubRepositoryAddress.parse(
            " https://github.com/Starcat-App/Starcat.git/issues/12 "
        )
        #expect(address == GitHubRepositoryAddress(owner: "Starcat-App", repo: "Starcat"))
        #expect(address?.canonicalURL.absoluteString == "https://github.com/Starcat-App/Starcat")
    }

    @Test("owner/repo 简写严格限制为两段")
    func parsesOwnerRepoShorthand() {
        #expect(
            GitHubRepositoryAddress.parse("openai/codex")
                == GitHubRepositoryAddress(owner: "openai", repo: "codex")
        )
        #expect(GitHubRepositoryAddress.parse("openai/codex/issues") == nil)
        #expect(GitHubRepositoryAddress.parse("openai") == nil)
    }

    @Test("拒绝非 GitHub host、保留路径与非法 owner")
    func rejectsNonRepositoryAddresses() {
        #expect(GitHubRepositoryAddress.parse("https://example.com/openai/codex") == nil)
        #expect(GitHubRepositoryAddress.parse("https://github.com/topics/swift") == nil)
        #expect(GitHubRepositoryAddress.parse("bad_owner/repo") == nil)
        #expect(GitHubRepositoryAddress.parse("-owner/repo") == nil)
    }

    @Test("批量幂等键忽略仓库顺序且对来源变化敏感")
    func idempotencyKeyIsStable() {
        let repositories = [
            CuratedPublisherImportRequest.Repository(
                owner: "OpenAI", repo: "Codex", title: "Codex", sourceURL: nil
            ),
            CuratedPublisherImportRequest.Repository(
                owner: "Apple", repo: "swift", title: nil, sourceURL: nil
            )
        ]
        let first = CuratedPublisherImportRequest.stableIdempotencyKey(
            sourceCode: "ai_intelligence",
            repositories: repositories
        )
        let second = CuratedPublisherImportRequest.stableIdempotencyKey(
            sourceCode: "AI_INTELLIGENCE",
            repositories: Array(repositories.reversed())
        )
        let changed = CuratedPublisherImportRequest.stableIdempotencyKey(
            sourceCode: "weekly",
            repositories: repositories
        )

        #expect(first == second)
        #expect(first != changed)
        #expect(first.hasPrefix("starcat-curated-"))
        #expect(first.count == "starcat-curated-".count + 64)
    }

    @Test("管理员密钥使用独立安全存储 namespace")
    func credentialStoreIsIsolated() throws {
        let keychain = InMemoryKeychain()
        try keychain.storeServiceAPIKey("ordinary-weekly-key", forService: "weekly")
        let store = CuratedPublisherCredentialStore(keychain: keychain)

        try store.storeAdminKey("admin-key")
        #expect(try store.loadAdminKey() == "admin-key")
        #expect(try keychain.loadServiceAPIKey(forService: "weekly") == "ordinary-weekly-key")

        try store.deleteAdminKey()
        #expect(try store.loadAdminKey() == nil)
        #expect(try keychain.loadServiceAPIKey(forService: "weekly") == "ordinary-weekly-key")
    }
}
