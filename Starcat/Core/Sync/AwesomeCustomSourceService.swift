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
    case duplicateSource
    case noValidRepositories

    var errorDescription: String? {
        switch self {
        case .invalidInput: return String.l10n("awesome.error.invalidSource")
        case .sourceMustBePublic: return String.l10n("awesome.error.publicOnly")
        case .sourceUnavailable: return String.l10n("awesome.error.sourceUnavailable")
        case .invalidReadmeEncoding: return String.l10n("awesome.error.invalidReadme")
        case .readmeTooLarge: return String.l10n("awesome.error.readmeTooLarge")
        case .duplicateSource: return String.l10n("awesome.error.duplicateSource")
        case .noValidRepositories: return String.l10n("awesome.error.noValidRepositories")
        }
    }
}

/// 自定义来源解析结果。Sheet 校验成功后立即交给 Repository 在当前账户数据库中持久化。
struct AwesomeCustomSourcePreview: Sendable {
    let source: AwesomeSource
    let entries: [AwesomeEntryDTO]
}

actor AwesomeCustomSourceService {
    private let github: any AwesomeGitHubClientProtocol
    private let repository: any AwesomeRepositoryProtocol

    init(github: any AwesomeGitHubClientProtocol, repository: any AwesomeRepositoryProtocol) {
        self.github = github
        self.repository = repository
    }

    func preview(input: String) async throws -> AwesomeCustomSourcePreview {
        guard let address = AwesomeSourceInput.parse(input) else {
            throw AwesomeCustomSourceError.invalidInput
        }
        let currentSources = await repository.sources()
        let existingRepoNames = Set(currentSources.map { $0.repoFullName.lowercased() })
        guard !existingRepoNames.contains(address.fullName.lowercased())
        else {
            throw AwesomeCustomSourceError.duplicateSource
        }
        let sourceRepo = try await github.awesomeRepository(owner: address.owner, repo: address.repo)
        guard !existingRepoNames.contains(sourceRepo.fullName.lowercased())
        else {
            // GitHub 可能把旧仓库名重定向到新 canonical 名称；核验后必须再检查一次，
            // 否则同一来源可通过 rename 前的 URL 绕过本地去重。
            throw AwesomeCustomSourceError.duplicateSource
        }
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
        guard !entries.isEmpty else {
            throw AwesomeCustomSourceError.noValidRepositories
        }

        let now = Date()
        let source = AwesomeSource(
            id: "custom:\(canonicalAddress.fullName.lowercased())",
            kind: .custom,
            displayName: sourceRepo.name,
            repoFullName: sourceRepo.fullName,
            repoURL: canonicalAddress.canonicalURL,
            repoDescription: sourceRepo.description,
            imageURL: sourceRepo.owner.avatarUrl.flatMap(URL.init(string:)),
            summaryZH: nil,
            summaryEN: sourceRepo.description,
            featured: false,
            sortOrder: Int.max,
            sourceStars: sourceRepo.stargazersCount,
            githubRepoCount: entries.count,
            externalEntryCount: parsed.externalLinkCount,
            isAvailable: true,
            // “添加”本身就是用户对自定义来源的明确提交动作；保存后立即启用，避免还要再点
            // Sheet 底部“完成”才生效。精选来源的批量勾选仍由“完成”统一提交。
            isEnabled: true,
            addedAt: now,
            lastSyncedAt: now,
            updatedAt: now
        )
        return AwesomeCustomSourcePreview(source: source, entries: entries)
    }

    func save(_ preview: AwesomeCustomSourcePreview) async throws {
        try await repository.saveCustomSource(preview.source, entries: preview.entries)
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
            homepage: repo.homepage,
            language: repo.language,
            stars: repo.stargazersCount,
            forks: repo.forksCount,
            watchers: repo.watchersCount,
            // GitHubRepoDTO 暂未暴露 subscribers_count；自定义来源不上传远端，保持本地已知值为 0。
            subscribers: 0,
            openIssues: repo.openIssuesCount ?? 0,
            defaultBranch: repo.defaultBranch ?? "",
            licenseSpdx: repo.license?.spdxId,
            topics: repo.topics ?? [],
            isArchived: repo.archived,
            isFork: repo.fork,
            pushedAt: repo.pushedAt,
            updatedAt: repo.updatedAt ?? "",
            createdAt: repo.createdAt ?? "",
            entryTitle: candidate.title,
            entryDescription: candidate.description,
            sectionPath: candidate.sectionPath,
            entryOrder: candidate.order,
            sourceAnchorURL: candidate.sourceAnchorURL.absoluteString
        )
    }
}
