//
//  AwesomeCustomSourceService.swift
//  Starcat
//
//  用户自定义 Awesome 来源的公开仓库核验、README 拉取、AST 解析和 Repo enrich 服务。
//
//  整批解析全部成功后才调用 Repository 原子替换，因此断网、限流或取消不会清空用户上一次
//  可用快照。404 / 私有条目按无效链接跳过；来源仓库本身必须公开且可用。
//

import Foundation

protocol AwesomeGitHubClientProtocol: Sendable {
    func awesomeRepository(owner: String, repo: String) async throws -> GitHubRepoDTO
    func awesomeReadme(owner: String, repo: String) async throws -> Data
}

extension GitHubAPIClient: AwesomeGitHubClientProtocol {
    func awesomeRepository(owner: String, repo: String) async throws -> GitHubRepoDTO {
        try await self.repo(owner: owner, repo: repo)
    }

    func awesomeReadme(owner: String, repo: String) async throws -> Data {
        try await readmeMarkdown(owner: owner, repo: repo).data
    }
}

enum AwesomeCustomSourceError: LocalizedError, Equatable {
    case invalidInput
    case sourceMustBePublic
    case sourceUnavailable
    case invalidReadmeEncoding
    case readmeTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidInput: return String.l10n("awesome.error.invalidSource")
        case .sourceMustBePublic: return String.l10n("awesome.error.publicOnly")
        case .sourceUnavailable: return String.l10n("awesome.error.sourceUnavailable")
        case .invalidReadmeEncoding: return String.l10n("awesome.error.invalidReadme")
        case .readmeTooLarge: return String.l10n("awesome.error.readmeTooLarge")
        }
    }
}

actor AwesomeCustomSourceService {
    private let github: any AwesomeGitHubClientProtocol
    private let repository: any AwesomeRepositoryProtocol

    init(github: any AwesomeGitHubClientProtocol, repository: any AwesomeRepositoryProtocol) {
        self.github = github
        self.repository = repository
    }

    @discardableResult
    func add(input: String) async throws -> AwesomeSource {
        guard let address = AwesomeSourceInput.parse(input) else {
            throw AwesomeCustomSourceError.invalidInput
        }
        let sourceRepo = try await github.awesomeRepository(owner: address.owner, repo: address.repo)
        guard !sourceRepo.isPrivate else { throw AwesomeCustomSourceError.sourceMustBePublic }
        guard !sourceRepo.archived, sourceRepo.disabled != true else {
            throw AwesomeCustomSourceError.sourceUnavailable
        }
        let data = try await github.awesomeReadme(owner: address.owner, repo: address.repo)
        guard let markdown = String(data: data, encoding: .utf8) else {
            throw AwesomeCustomSourceError.invalidReadmeEncoding
        }
        let canonicalAddress = AwesomeRepositoryAddress(
            owner: sourceRepo.owner.login,
            repo: sourceRepo.name
        )
        let parsed = try AwesomeReadmeParser.parse(
            markdown: markdown,
            source: canonicalAddress,
            defaultBranch: sourceRepo.defaultBranch ?? "main"
        )

        var entries: [AwesomeEntryDTO] = []
        var seenRepoIDs: Set<Int64> = []
        for candidate in parsed.githubLinks {
            try Task.checkCancellation()
            do {
                let repo = try await github.awesomeRepository(
                    owner: candidate.address.owner,
                    repo: candidate.address.repo
                )
                guard !repo.isPrivate, repo.disabled != true, seenRepoIDs.insert(repo.id).inserted else { continue }
                entries.append(Self.entry(from: repo, candidate: candidate))
            } catch NetworkError.notFound {
                // README 中失效链接是来源质量事实，不应让整个自定义来源无法添加。
                continue
            }
        }

        let now = Date()
        let source = AwesomeSource(
            id: "custom:\(canonicalAddress.fullName.lowercased())",
            kind: .custom,
            displayName: sourceRepo.name,
            repoFullName: sourceRepo.fullName,
            repoURL: canonicalAddress.canonicalURL,
            imageURL: sourceRepo.owner.avatarUrl.flatMap(URL.init(string:)),
            summaryZH: nil,
            summaryEN: sourceRepo.description,
            featured: false,
            sortOrder: Int.max,
            githubRepoCount: entries.count,
            externalEntryCount: parsed.externalLinkCount,
            isAvailable: true,
            isEnabled: true,
            addedAt: now,
            updatedAt: now
        )
        try await repository.saveCustomSource(source, entries: entries)
        return source
    }

    func remove(sourceID: String) async throws {
        try await repository.removeCustomSource(id: sourceID)
    }

    private static func entry(from repo: GitHubRepoDTO, candidate: ParsedAwesomeLink) -> AwesomeEntryDTO {
        AwesomeEntryDTO(
            ghRepoID: repo.id,
            owner: repo.owner.login,
            name: repo.name,
            fullName: repo.fullName,
            description: repo.description,
            ownerAvatar: repo.owner.avatarUrl,
            language: repo.language,
            stars: repo.stargazersCount,
            isArchived: repo.archived,
            updatedAt: repo.updatedAt,
            entryTitle: candidate.title,
            entryDescription: candidate.description,
            sectionPath: candidate.sectionPath,
            entryOrder: candidate.order,
            sourceAnchorURL: candidate.sourceAnchorURL.absoluteString
        )
    }
}
