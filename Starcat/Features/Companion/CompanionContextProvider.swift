//
//  CompanionContextProvider.swift
//  Starcat
//
//  Browser Plugin repo-context 聚合入口。
//
//  当前先完成请求校验与 Repo 基础信息映射。推荐、Wiki、Notes、Health、OpenSSF
//  后续按分组增量接入, 但对外 DTO 契约从第一步就固定下来。
//

import Foundation

enum CompanionContextError: Error, Equatable {
    case invalidRepoPath
}

/// Companion 只需要推荐页的展示数据与“是否还有下一页”。nextOffset 仍由
/// `RecommendationContextService` 的磁盘快照持有，不能交给浏览器决定。
private struct CompanionRecommendationPageSource {
    let items: [RepoRecommendationItem]
    let hasMore: Bool
}

struct CompanionContextProvider {
    private let lookupRepo: @Sendable (String, String) async throws -> Repo?
    private let lookupLibraryState: @Sendable (Int64) async throws -> LibraryState
    private let lookupNote: @Sendable (Int64) async throws -> RepoNote?
    private let lookupTags: @Sendable (Int64) async throws -> [Tag]
    private let lookupAllTags: @Sendable () async throws -> [Tag]
    private let lookupLatestSummary: @Sendable (Int64) async throws -> AISummaryRecord?
    private let lookupHealth: @Sendable (Int64) async throws -> RepoHealthSnapshot?
    private let lookupOpenSSF: @Sendable (Int64) async throws -> OpenSSFScoreRecord?
    private let lookupWikiLinks: @Sendable (String, String) async -> [WikiLink]
    private let lookupRecommendationPage: @Sendable (Int64) async throws -> CompanionRecommendationPageSource
    private let isProUser: @Sendable () async -> Bool

    init(
        repoRepository: any RepoRepositoryProtocol,
        noteRepository: (any RepoNoteRepositoryProtocol)? = nil,
        tagRepository: (any TagRepositoryProtocol)? = nil,
        repoTagRepository: (any RepoTagRepositoryProtocol)? = nil,
        summaryRepository: (any AISummaryRepositoryProtocol)? = nil,
        healthRepository: (any RepoHealthRepositoryProtocol)? = nil,
        openSSFRepository: (any OpenSSFScoreRepositoryProtocol)? = nil,
        wikiContextService: WikiContextService? = nil,
        recommendationContextService: RecommendationContextService? = nil,
        entitlementGate: EntitlementGate? = nil
    ) {
        lookupRepo = { owner, name in
            try await repoRepository.findByOwnerName(owner: owner, name: name)
        }
        lookupLibraryState = { repoID in
            try await noteRepository?.fetchLibraryState(repoId: repoID) ?? .outsideLibrary
        }
        lookupNote = { repoID in
            try await noteRepository?.find(repoId: repoID)
        }
        lookupTags = { repoID in
            try await repoTagRepository?.fetchTags(forRepo: repoID) ?? []
        }
        lookupAllTags = {
            try await tagRepository?.fetchAll() ?? []
        }
        lookupLatestSummary = { repoID in
            try await summaryRepository?.fetchLatestPerRepo()[repoID]
        }
        lookupHealth = { repoID in
            try await healthRepository?.snapshot(for: repoID)
        }
        lookupOpenSSF = { repoID in
            try await openSSFRepository?.record(for: repoID)
        }
        lookupWikiLinks = { owner, name in
            guard let wikiContextService else { return [] }
            return await MainActor.run {
                wikiContextService.cacheFirstLinks(owner: owner, repo: name, isPrivate: false)
            }
        }
        lookupRecommendationPage = { repoID in
            guard let recommendationContextService else {
                return CompanionRecommendationPageSource(items: [], hasMore: false)
            }
            let serviceScope = await recommendationContextService.currentServiceScope()
            if let cached = await recommendationContextService.cachedSnapshot(
                repoID: repoID,
                serviceScope: serviceScope
            ) {
                return CompanionRecommendationPageSource(items: cached.items, hasMore: cached.hasMore)
            }
            let fresh = try await recommendationContextService.refresh(
                repoID: repoID,
                serviceScope: serviceScope
            )
            return CompanionRecommendationPageSource(items: fresh.items, hasMore: fresh.hasMore)
        }
        isProUser = {
            await MainActor.run {
                entitlementGate?.isProUser ?? false
            }
        }
    }

    /// 测试专用注入点。用闭包替代假 Repository, 避免为了一个查询实现整套协议。
    init(
        lookupRepo: @escaping @Sendable (String, String) async throws -> Repo?,
        lookupLibraryState: @escaping @Sendable (Int64) async throws -> LibraryState = { _ in .outsideLibrary },
        lookupNote: @escaping @Sendable (Int64) async throws -> RepoNote? = { _ in nil },
        lookupTags: @escaping @Sendable (Int64) async throws -> [Tag] = { _ in [] },
        lookupAllTags: @escaping @Sendable () async throws -> [Tag] = { [] },
        lookupLatestSummary: @escaping @Sendable (Int64) async throws -> AISummaryRecord? = { _ in nil },
        lookupHealth: @escaping @Sendable (Int64) async throws -> RepoHealthSnapshot? = { _ in nil },
        lookupOpenSSF: @escaping @Sendable (Int64) async throws -> OpenSSFScoreRecord? = { _ in nil },
        lookupWikiLinks: @escaping @Sendable (String, String) async -> [WikiLink] = { _, _ in [] },
        lookupRecommendations: @escaping @Sendable (Int64) async throws -> [RepoRecommendationItem] = { _ in [] },
        lookupRecommendationsHasMore: @escaping @Sendable (Int64) async throws -> Bool = { _ in false },
        isProUser: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.lookupRepo = lookupRepo
        self.lookupLibraryState = lookupLibraryState
        self.lookupNote = lookupNote
        self.lookupTags = lookupTags
        self.lookupAllTags = lookupAllTags
        self.lookupLatestSummary = lookupLatestSummary
        self.lookupHealth = lookupHealth
        self.lookupOpenSSF = lookupOpenSSF
        self.lookupWikiLinks = lookupWikiLinks
        lookupRecommendationPage = { repoID in
            CompanionRecommendationPageSource(
                items: try await lookupRecommendations(repoID),
                hasMore: try await lookupRecommendationsHasMore(repoID)
            )
        }
        self.isProUser = isProUser
    }

    func context(owner rawOwner: String, repo rawRepo: String) async throws -> CompanionRepoContextResponse {
        let owner = rawOwner.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = rawRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidGitHubPathComponent(owner), Self.isValidGitHubPathComponent(name) else {
            throw CompanionContextError.invalidRepoPath
        }

        let localRepo = try await lookupRepo(owner, name)
        let libraryState = await libraryState(for: localRepo)
        let hasProEntitlement = await isProUser()
        let note = await noteDTO(for: localRepo, libraryState: libraryState)
        let tags = await tagDTOs(for: localRepo, libraryState: libraryState)
        let availableTags = await allTagDTOs(for: localRepo, libraryState: libraryState)
        // Companion API is reachable from the browser extension, so Pro-only data
        // is cut at the local API boundary instead of relying on content-script UI
        // hiding. Private notes remain available for starred repos because they are
        // first-party local data, not one of the paid external insight surfaces.
        let aiSummary = hasProEntitlement
            ? await summaryDTO(for: localRepo, libraryState: libraryState)
            : nil
        let health = hasProEntitlement ? await healthDTO(for: localRepo) : nil
        let openssf = hasProEntitlement ? await openSSFDTO(for: localRepo) : nil
        let wikiLinks = hasProEntitlement && localRepo?.isPrivate != true
            ? await wikiLinkDTOs(owner: owner, name: name)
            : []
        let recommendationPage = hasProEntitlement
            ? await recommendationPageDTO(for: localRepo)
            : CompanionRecommendationsPageResponse(
                schemaVersion: 1,
                status: "ok",
                recommendations: [],
                hasMore: false
            )
        let canOpenLocalActions = isActiveLocalRepo(localRepo, libraryState: libraryState)
            && hasProEntitlement
        return CompanionRepoContextResponse(
            schemaVersion: 1,
            repo: Self.repoDTO(owner: owner, name: name, localRepo: localRepo, libraryState: libraryState),
            recommendations: recommendationPage.recommendations,
            recommendationsHasMore: recommendationPage.hasMore,
            wikiLinks: wikiLinks,
            tags: tags,
            availableTags: availableTags,
            aiSummary: aiSummary,
            note: note,
            health: health,
            openssf: openssf,
            actions: CompanionActionsDTO(
                openInStarcat: canOpenLocalActions,
                generateSummary: canOpenLocalActions,
                codeflow: canOpenLocalActions,
                codebase: canOpenLocalActions
            ),
            entitlement: CompanionEntitlementDTO(isPro: hasProEntitlement)
        )
    }

    private func recommendationPageDTO(for repo: Repo?) async -> CompanionRecommendationsPageResponse {
        guard let repo, repo.id > 0 else {
            return CompanionRecommendationsPageResponse(
                schemaVersion: 1,
                status: "ok",
                recommendations: [],
                hasMore: false
            )
        }
        do {
            let page = try await lookupRecommendationPage(repo.id)
            return CompanionRecommendationsPageResponse(
                schemaVersion: 1,
                status: "ok",
                recommendations: page.items.map(Self.recommendationDTO(_:)),
                hasMore: page.hasMore
            )
        } catch {
            return CompanionRecommendationsPageResponse(
                schemaVersion: 1,
                status: "ok",
                recommendations: [],
                hasMore: false
            )
        }
    }

    static func recommendationDTO(_ item: RepoRecommendationItem) -> CompanionRecommendationDTO {
        CompanionRecommendationDTO(
            repoID: item.repoID,
            fullName: item.fullName,
            description: item.description,
            language: item.language,
            stars: item.stars,
            score: item.score,
            reason: item.reasons.first
        )
    }

    private func wikiLinkDTOs(owner: String, name: String) async -> [CompanionWikiLinkDTO] {
        let links = await lookupWikiLinks(owner, name)
        return links.map { link in
            CompanionWikiLinkDTO(
                source: link.source.rawValue,
                title: Self.englishWikiTitle(for: link.source),
                url: link.url.absoluteString
            )
        }
    }

    private func libraryState(for repo: Repo?) async -> LibraryState {
        guard let repo else { return .outsideLibrary }
        return (try? await lookupLibraryState(repo.id)) ?? .outsideLibrary
    }

    private func isActiveLocalRepo(_ repo: Repo?, libraryState: LibraryState) -> Bool {
        guard let repo else { return false }
        return repo.isStarred || libraryState == .inLibrary
    }

    private func tagDTOs(for repo: Repo?, libraryState: LibraryState) async -> [CompanionTagDTO] {
        guard let repo, isActiveLocalRepo(repo, libraryState: libraryState) else { return [] }
        do {
            return try await lookupTags(repo.id).map(Self.tagDTO(_:))
        } catch {
            return []
        }
    }

    private func allTagDTOs(for repo: Repo?, libraryState: LibraryState) async -> [CompanionTagDTO] {
        guard isActiveLocalRepo(repo, libraryState: libraryState) else { return [] }
        do {
            return try await lookupAllTags().map(Self.tagDTO(_:))
        } catch {
            return []
        }
    }

    private func summaryDTO(for repo: Repo?, libraryState: LibraryState) async -> CompanionAISummaryDTO? {
        guard let repo, isActiveLocalRepo(repo, libraryState: libraryState) else { return nil }
        do {
            guard let record = try await lookupLatestSummary(repo.id) else { return nil }
            return Self.summaryDTO(record)
        } catch {
            return nil
        }
    }

    private func healthDTO(for repo: Repo?) async -> CompanionHealthDTO? {
        guard let repo else { return nil }
        guard let snapshot = try? await lookupHealth(repo.id),
              snapshot.badgeData != nil else { return nil }
        return CompanionHealthDTO(
            score: snapshot.overallScore,
            grade: snapshot.grade,
            computedAt: snapshot.computedAt
        )
    }

    private func openSSFDTO(for repo: Repo?) async -> CompanionOpenSSFDTO? {
        guard let repo else { return nil }
        guard let record = try? await lookupOpenSSF(repo.id),
              let badge = record.badgeData else { return nil }
        return CompanionOpenSSFDTO(
            score: badge.score,
            scoreDate: record.scoreDate
        )
    }

    private func noteDTO(for repo: Repo?, libraryState: LibraryState) async -> CompanionNoteDTO? {
        guard let repo, isActiveLocalRepo(repo, libraryState: libraryState) else { return nil }
        let note = try? await lookupNote(repo.id)
        return CompanionNoteDTO(
            editable: true,
            content: note?.content ?? "",
            editedAt: note?.editedAt
        )
    }

    private static func repoDTO(
        owner: String,
        name: String,
        localRepo: Repo?,
        libraryState: LibraryState
    ) -> CompanionRepoDTO {
        if let localRepo {
            return CompanionRepoDTO(
                owner: localRepo.owner,
                name: localRepo.name,
                fullName: localRepo.fullName,
                repoID: localRepo.id,
                htmlURL: localRepo.htmlUrl,
                knownToStarcat: true,
                isStarred: localRepo.isStarred,
                libraryState: libraryState.rawValue,
                isInLibrary: libraryState == .inLibrary
            )
        }

        let fullName = "\(owner)/\(name)"
        return CompanionRepoDTO(
            owner: owner,
            name: name,
            fullName: fullName,
            repoID: nil,
            htmlURL: "https://github.com/\(fullName)",
            knownToStarcat: false,
            isStarred: false,
            libraryState: LibraryState.outsideLibrary.rawValue,
            isInLibrary: false
        )
    }

    static func tagDTO(_ tag: Tag) -> CompanionTagDTO {
        CompanionTagDTO(
            id: tag.id,
            name: tag.name,
            color: tag.color,
            icon: tag.icon
        )
    }

    static func summaryDTO(_ record: AISummaryRecord) -> CompanionAISummaryDTO? {
        guard let insight = try? RepoAIInsightService.decodeInsight(json: record.summaryJson) else {
            return nil
        }
        let markdown = normalizedNonEmpty(insight.summaryMarkdown) ?? normalizedNonEmpty(insight.summary)
        guard let markdown else { return nil }
        return CompanionAISummaryDTO(
            markdown: markdown,
            model: normalizedNonEmpty(insight.model),
            generatedAt: normalizedNonEmpty(insight.generatedAt) ?? normalizedNonEmpty(record.generatedAt)
        )
    }

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    static func isValidGitHubPathComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 100 else { return false }
        return value.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber || character == "." || character == "_" || character == "-")
        }
    }

    private static func englishWikiTitle(for source: WikiSource) -> String {
        switch source {
        case .deepWiki: return "DeepWiki"
        case .zread: return "ZRead"
        case .codeWiki: return "CodeWiki"
        case .unknown(let raw): return raw
        }
    }
}
