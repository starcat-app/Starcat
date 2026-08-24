//
//  AwesomeReadmeParserTests.swift
//  StarcatTests
//
//  自定义 Awesome 输入归一化、AST 结构提取和公开仓库核验测试。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Awesome README Parser")
struct AwesomeReadmeParserTests {

    @Test("来源输入只接受 owner/repo 与 HTTPS GitHub 仓库根地址")
    func sourceInputNormalization() {
        #expect(AwesomeSourceInput.parse("owner/repo")?.fullName == "owner/repo")
        #expect(AwesomeSourceInput.parse("https://github.com/owner/repo.git")?.fullName == "owner/repo")
        #expect(AwesomeSourceInput.parse("http://github.com/owner/repo") == nil)
        #expect(AwesomeSourceInput.parse("https://gitlab.com/owner/repo") == nil)
        #expect(AwesomeSourceInput.parse("https://github.com/owner/repo/issues") == nil)
    }

    @Test("AST 解析保留章节、描述、嵌套顺序并统计外部链接")
    func parsesStructuredEntries() throws {
        let markdown = """
        # Awesome Example
        ## Tools
        - [First](https://github.com/acme/first) - First description
          - [Nested](https://github.com/acme/nested) — Nested description
        - [Website](https://example.com/product) - external
        ## Libraries
        - [Second](https://github.com/acme/second) - Second description
        """

        let result = try AwesomeReadmeParser.parse(
            markdown: markdown,
            source: AwesomeRepositoryAddress(owner: "example", repo: "awesome"),
            defaultBranch: "main"
        )

        #expect(result.githubLinks.map(\.address.fullName) == ["acme/first", "acme/nested", "acme/second"])
        #expect(result.githubLinks[0].sectionPath == ["Awesome Example", "Tools"])
        #expect(result.githubLinks[0].description == "First description")
        #expect(result.githubLinks[1].description == "Nested description")
        #expect(result.githubLinks[2].sectionPath == ["Awesome Example", "Libraries"])
        #expect(result.githubLinks.map(\.order) == [0, 1, 2])
        #expect(result.externalLinkCount == 1)
        #expect(result.githubLinks[0].sourceAnchorURL.absoluteString.hasSuffix("#tools"))
    }

    @Test("自定义来源拒绝私有来源仓库")
    func customSourceRejectsPrivateRepository() async throws {
        let github = FakeAwesomeGitHub()
        await github.setRepo(Self.repo(id: 1, fullName: "owner/private-list", isPrivate: true))
        let repository = FakeAwesomeRepository()
        let service = AwesomeCustomSourceService(github: github, repository: repository)

        await #expect(throws: AwesomeCustomSourceError.sourceMustBePublic) {
            try await service.preview(input: "owner/private-list")
        }
        #expect(await repository.savedSource() == nil)
    }

    @Test("自定义来源解析完成后一次性保存并跳过失效 Repo")
    func customSourceSavesVerifiedSnapshot() async throws {
        let github = FakeAwesomeGitHub()
        await github.setRepo(Self.repo(id: 1, fullName: "owner/awesome-list"))
        await github.setRepo(Self.repo(id: 2, fullName: "acme/valid"))
        await github.markMissing("acme/missing")
        await github.setReadme(
            "owner/awesome-list",
            markdown: """
            ## Tools
            - [Valid](https://github.com/acme/valid) - Works
            - [Missing](https://github.com/acme/missing) - Gone
            """
        )
        let repository = FakeAwesomeRepository()
        let service = AwesomeCustomSourceService(github: github, repository: repository)

        let preview = try await service.preview(input: "https://github.com/owner/awesome-list")

        #expect(preview.source.id == "custom:owner/awesome-list")
        #expect(preview.source.githubRepoCount == 1)
        #expect(preview.source.isEnabled)
        #expect(await repository.savedSource() == nil)

        try await service.save(preview)
        let saved = await repository.savedSource()
        #expect(saved?.entries.map(\.fullName) == ["acme/valid"])
        #expect(saved?.entries.first?.forks == 1)
        #expect(saved?.entries.first?.watchers == 10)
        #expect(saved?.entries.first?.defaultBranch == "main")
        #expect(saved?.entries.first?.sectionPath == ["Tools"])
    }

    @Test("自定义来源拒绝与现有精选或自定义来源重复")
    func customSourceRejectsDuplicateCanonicalRepository() async throws {
        let github = FakeAwesomeGitHub()
        let repository = FakeAwesomeRepository(existingSources: [Self.existingSource()])
        let service = AwesomeCustomSourceService(github: github, repository: repository)

        await #expect(throws: AwesomeCustomSourceError.duplicateSource) {
            try await service.preview(input: "https://github.com/OWNER/AWESOME-LIST")
        }
    }

    @Test("自定义来源没有有效 GitHub Repo 时不保存")
    func customSourceRequiresAtLeastOneValidRepository() async throws {
        let github = FakeAwesomeGitHub()
        await github.setRepo(Self.repo(id: 1, fullName: "owner/awesome-list"))
        await github.setReadme(
            "owner/awesome-list",
            markdown: "- [External](https://example.com/tool) - Not a GitHub repository"
        )
        let repository = FakeAwesomeRepository()
        let service = AwesomeCustomSourceService(github: github, repository: repository)

        await #expect(throws: AwesomeCustomSourceError.noValidRepositories) {
            try await service.preview(input: "owner/awesome-list")
        }
        #expect(await repository.savedSource() == nil)
    }

    private static func repo(
        id: Int64,
        fullName: String,
        isPrivate: Bool = false
    ) -> GitHubRepoDTO {
        let parts = fullName.split(separator: "/").map(String.init)
        return GitHubRepoDTO(
            id: id,
            name: parts[1],
            fullName: fullName,
            owner: GitHubUserDTO(id: id, login: parts[0], name: nil, avatarUrl: nil),
            description: "Description",
            language: "Swift",
            stargazersCount: 10,
            forksCount: 1,
            watchersCount: 10,
            topics: [],
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/\(fullName)",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: isPrivate,
            fork: false,
            archived: false,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            openIssuesCount: 0,
            defaultBranch: "main",
            disabled: false,
            isTemplate: false,
            score: nil
        )
    }

    private static func existingSource() -> AwesomeSource {
        AwesomeSource(
            id: "managed",
            kind: .managed,
            displayName: "Existing",
            repoFullName: "owner/awesome-list",
            repoURL: URL(string: "https://github.com/owner/awesome-list")!,
            repoDescription: "Existing GitHub description",
            imageURL: nil,
            summaryZH: nil,
            summaryEN: nil,
            featured: false,
            sortOrder: 1,
            sourceStars: 0,
            githubRepoCount: 1,
            externalEntryCount: 0,
            isAvailable: true,
            isEnabled: false,
            addedAt: .distantPast,
            lastSyncedAt: .distantPast,
            updatedAt: .distantPast
        )
    }
}

private actor FakeAwesomeGitHub: AwesomeGitHubClientProtocol {
    private var repos: [String: GitHubRepoDTO] = [:]
    private var readmes: [String: Data] = [:]
    private var missing: Set<String> = []

    func setRepo(_ repo: GitHubRepoDTO) { repos[repo.fullName.lowercased()] = repo }
    func setReadme(_ fullName: String, markdown: String) { readmes[fullName.lowercased()] = Data(markdown.utf8) }
    func markMissing(_ fullName: String) { missing.insert(fullName.lowercased()) }

    func awesomeRepository(owner: String, repo: String) async throws -> GitHubRepoDTO {
        let key = "\(owner)/\(repo)".lowercased()
        if missing.contains(key) { throw NetworkError.notFound }
        guard let value = repos[key] else { throw NetworkError.notFound }
        return value
    }

    func awesomeReadme(owner: String, repo: String) async throws -> Data {
        readmes["\(owner)/\(repo)".lowercased()] ?? Data()
    }
}

private actor FakeAwesomeRepository: AwesomeRepositoryProtocol {
    struct Saved: Sendable {
        let source: AwesomeSource
        let entries: [AwesomeEntryDTO]
    }

    private var saved: Saved?
    private var existingSources: [AwesomeSource]

    init(existingSources: [AwesomeSource] = []) {
        self.existingSources = existingSources
    }

    func savedSource() -> Saved? { saved }
    func sources() async -> [AwesomeSource] {
        existingSources + (saved.map { [$0.source] } ?? [])
    }
    func enabledSources() async -> [AwesomeSource] { await sources().filter(\.isEnabled) }
    func repositories(sourceID: String?) async -> [AwesomeRepositoryItem] { [] }
    func hasCompletedSourceSetup() async -> Bool { false }
    func refreshCatalog(policy: AwesomeRefreshPolicy) async throws -> [AwesomeSource] { [] }
    func refreshEnabledEntries(policy: AwesomeRefreshPolicy) async -> [String: String] { [:] }
    func completeSourceSetup(enabledSourceIDs: Set<String>) async throws {}
    func updateSubscriptions(enabledSourceIDs: Set<String>) async throws {}
    func removeCustomSource(id: String) async throws {}

    func saveCustomSource(_ source: AwesomeSource, entries: [AwesomeEntryDTO]) async throws {
        saved = Saved(source: source, entries: entries)
    }
}
