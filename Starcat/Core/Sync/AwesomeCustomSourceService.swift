//
//  AwesomeCustomSourceService.swift
//  Starcat
//
//  用户自定义 Awesome 来源的公开仓库核验、README 拉取、AST 解析和 Repo enrich 服务。
//
//  来源仓库核验后立即创建本地卡片，README 和条目仓库随后在后台分批解析。失败保留
//  已落库批次并允许重试；404 / 私有条目按无效链接跳过，来源仓库本身必须公开且可用。
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

/// 快速核验返回值。默认分支仅在本次添加后复用；重启恢复时会重新读取来源仓库元数据。
struct AwesomeCustomSourceCreation: Sendable {
    let source: AwesomeSource
    let defaultBranch: String
}

actor AwesomeCustomSourceService {
    private static let persistenceBatchSize = 20

    private let github: any AwesomeGitHubClientProtocol
    private let repository: any AwesomeRepositoryProtocol
    private let now: @Sendable () -> Date

    init(
        github: any AwesomeGitHubClientProtocol,
        repository: any AwesomeRepositoryProtocol,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.github = github
        self.repository = repository
        self.now = now
    }

    /// 只核验输入和来源仓库本身，然后立即持久化空卡片。README 与其中几百个仓库的
    /// 请求必须留给后台任务，否则添加按钮会一直旋转到整份清单解析完毕。
    func create(input: String) async throws -> AwesomeCustomSourceCreation {
        let (sourceRepo, canonicalAddress) = try await validatedSourceRepository(input: input)
        let createdAt = now()
        let source = Self.source(
            from: sourceRepo,
            address: canonicalAddress,
            githubRepoCount: 0,
            externalEntryCount: 0,
            lastSyncedAt: nil,
            now: createdAt
        )
        let queued = AwesomeCustomSourceParseState(
            sourceID: source.id,
            phase: .queued,
            processedCount: 0,
            totalCount: nil,
            errorMessage: nil,
            updatedAt: createdAt
        )
        try await repository.saveCustomSource(source, entries: [], parseState: queued)
        return AwesomeCustomSourceCreation(
            source: source,
            defaultBranch: sourceRepo.defaultBranch ?? "main"
        )
    }

    /// 本机后台解析并按 20 个候选一批持久化。每批同时提交条目和进度，使中栏可逐步
    /// 展示已完成数据；失败保留部分结果，重试与重启会跳过已落库的同名仓库。
    func parse(
        source: AwesomeSource,
        defaultBranch: String? = nil,
        onStateChange: @escaping @Sendable (AwesomeCustomSourceParseState) async -> Void
    ) async throws {
        var processedCount = 0
        var totalCount: Int?
        do {
            let reading = parseState(
                sourceID: source.id,
                phase: .readingReadme,
                processedCount: 0,
                totalCount: nil
            )
            try await publish(reading, onStateChange: onStateChange)

            guard let address = AwesomeSourceInput.parse(source.repoFullName) else {
                throw AwesomeCustomSourceError.invalidInput
            }
            let resolvedBranch: String
            if let defaultBranch {
                resolvedBranch = defaultBranch
            } else {
                // 恢复未完成任务时内存里的默认分支已经丢失；只补一次来源仓库请求，之后
                // 仍按本地已有条目跳过 enrich，避免重复消耗大量 GitHub 限额。
                let sourceRepo = try await github.awesomeRepository(owner: address.owner, repo: address.repo)
                resolvedBranch = sourceRepo.defaultBranch ?? "main"
            }
            let data = try await github.awesomeReadme(owner: address.owner, repo: address.repo)
            guard let markdown = String(data: data, encoding: .utf8) else {
                throw AwesomeCustomSourceError.invalidReadmeEncoding
            }
            let parsed = try AwesomeReadmeParser.parse(
                markdown: markdown,
                source: address,
                defaultBranch: resolvedBranch
            )
            totalCount = parsed.githubLinks.count
            var savedFullNames = await repository.customSourceEntryFullNames(sourceID: source.id)
            var batch: [AwesomeEntryDTO] = []
            var seenRepoIDs: Set<Int64> = []

            let enriching = parseState(
                sourceID: source.id,
                phase: .enrichingRepositories,
                processedCount: 0,
                totalCount: totalCount
            )
            try await publish(enriching, onStateChange: onStateChange)

            for candidate in parsed.githubLinks {
                try Task.checkCancellation()
                let candidateName = candidate.address.fullName.lowercased()
                if !savedFullNames.contains(candidateName) {
                    do {
                        let repo = try await github.awesomeRepository(
                            owner: candidate.address.owner,
                            repo: candidate.address.repo
                        )
                        if !repo.isPrivate,
                           repo.disabled != true,
                           seenRepoIDs.insert(repo.id).inserted {
                            batch.append(Self.entry(from: repo, candidate: candidate))
                            savedFullNames.insert(repo.fullName.lowercased())
                        }
                    } catch NetworkError.notFound {
                        // README 中的失效链接只计入已处理进度，不阻断其它有效仓库。
                    }
                }
                processedCount += 1

                // 进度按候选数分批，而不是按成功条目数分批。即使一段 README 中连续出现
                // 失效链接，用户也能看到进度前进，不会误以为解析卡死。
                if processedCount.isMultiple(of: Self.persistenceBatchSize) || processedCount == totalCount {
                    let progress = parseState(
                        sourceID: source.id,
                        phase: .enrichingRepositories,
                        processedCount: processedCount,
                        totalCount: totalCount
                    )
                    try await repository.saveCustomSourceEntries(
                        batch,
                        sourceID: source.id,
                        parseState: progress
                    )
                    batch.removeAll(keepingCapacity: true)
                    await onStateChange(progress)
                }
            }

            guard await repository.customSourceEntryCount(sourceID: source.id) > 0 else {
                throw AwesomeCustomSourceError.noValidRepositories
            }
            let completed = parseState(
                sourceID: source.id,
                phase: .completed,
                processedCount: processedCount,
                totalCount: totalCount
            )
            try await repository.completeCustomSourceParsing(
                sourceID: source.id,
                externalEntryCount: parsed.externalLinkCount,
                parseState: completed
            )
            await onStateChange(completed)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failed = parseState(
                sourceID: source.id,
                phase: .failed,
                processedCount: processedCount,
                totalCount: totalCount,
                errorMessage: error.localizedDescription
            )
            try? await repository.updateCustomSourceParseState(failed)
            await onStateChange(failed)
            throw error
        }
    }

    func remove(sourceID: String) async throws {
        try await repository.removeCustomSource(id: sourceID)
    }

    private func validatedSourceRepository(
        input: String
    ) async throws -> (GitHubRepoDTO, AwesomeRepositoryAddress) {
        guard let address = AwesomeSourceInput.parse(input) else {
            throw AwesomeCustomSourceError.invalidInput
        }
        let currentSources = await repository.sources()
        let existingRepoNames = Set(currentSources.map { $0.repoFullName.lowercased() })
        guard !existingRepoNames.contains(address.fullName.lowercased()) else {
            throw AwesomeCustomSourceError.duplicateSource
        }
        let sourceRepo = try await github.awesomeRepository(owner: address.owner, repo: address.repo)
        guard !existingRepoNames.contains(sourceRepo.fullName.lowercased()) else {
            // GitHub 可能把旧仓库名重定向到 canonical 名称，核验后必须再去重。
            throw AwesomeCustomSourceError.duplicateSource
        }
        guard !sourceRepo.isPrivate else { throw AwesomeCustomSourceError.sourceMustBePublic }
        guard !sourceRepo.archived, sourceRepo.disabled != true else {
            throw AwesomeCustomSourceError.sourceUnavailable
        }
        return (
            sourceRepo,
            AwesomeRepositoryAddress(owner: sourceRepo.owner.login, repo: sourceRepo.name)
        )
    }

    private func parseState(
        sourceID: String,
        phase: AwesomeCustomSourceParsePhase,
        processedCount: Int,
        totalCount: Int?,
        errorMessage: String? = nil
    ) -> AwesomeCustomSourceParseState {
        AwesomeCustomSourceParseState(
            sourceID: sourceID,
            phase: phase,
            processedCount: processedCount,
            totalCount: totalCount,
            errorMessage: errorMessage,
            updatedAt: now()
        )
    }

    private func publish(
        _ state: AwesomeCustomSourceParseState,
        onStateChange: @escaping @Sendable (AwesomeCustomSourceParseState) async -> Void
    ) async throws {
        try await repository.updateCustomSourceParseState(state)
        await onStateChange(state)
    }

    private static func source(
        from sourceRepo: GitHubRepoDTO,
        address: AwesomeRepositoryAddress,
        githubRepoCount: Int,
        externalEntryCount: Int,
        lastSyncedAt: Date?,
        now: Date
    ) -> AwesomeSource {
        AwesomeSource(
            id: "custom:\(address.fullName.lowercased())",
            kind: .custom,
            displayName: sourceRepo.name,
            repoFullName: sourceRepo.fullName,
            repoURL: address.canonicalURL,
            repoDescription: sourceRepo.description,
            imageURL: sourceRepo.owner.avatarUrl.flatMap(URL.init(string:)),
            summaryZH: nil,
            summaryEN: sourceRepo.description,
            featured: false,
            sortOrder: Int.max,
            sourceStars: sourceRepo.stargazersCount,
            sourceForks: sourceRepo.forksCount,
            sourceWatchers: sourceRepo.watchersCount,
            sourceSubscribers: 0,
            sourceOpenIssues: sourceRepo.openIssuesCount ?? 0,
            sourceLanguage: sourceRepo.language,
            // 自定义来源只调用本机已有的仓库详情接口，不请求 Discovery API。
            languageBytes: sourceRepo.language.map { [$0: 1] } ?? [:],
            githubRepoCount: githubRepoCount,
            externalEntryCount: externalEntryCount,
            resourceEntryCount: 0,
            isAvailable: true,
            isEnabled: true,
            addedAt: now,
            lastSyncedAt: lastSyncedAt,
            updatedAt: now
        )
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
