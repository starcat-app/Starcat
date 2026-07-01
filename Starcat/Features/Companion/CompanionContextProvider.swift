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

struct CompanionContextProvider {
    private let lookupRepo: @Sendable (String, String) async throws -> Repo?
    private let lookupNote: @Sendable (Int64) async throws -> RepoNote?
    private let lookupHealth: @Sendable (Int64) async throws -> RepoHealthSnapshot?
    private let lookupOpenSSF: @Sendable (Int64) async throws -> OpenSSFScoreRecord?
    private let lookupWikiLinks: @Sendable (String, String) async -> [WikiLink]
    private let lookupRecommendations: @Sendable (Int64) async throws -> [RepoRecommendationItem]
    private let isProUser: @Sendable () async -> Bool

    init(
        repoRepository: any RepoRepositoryProtocol,
        noteRepository: (any RepoNoteRepositoryProtocol)? = nil,
        healthRepository: (any RepoHealthRepositoryProtocol)? = nil,
        openSSFRepository: (any OpenSSFScoreRepositoryProtocol)? = nil,
        wikiContextService: WikiContextService? = nil,
        recommendationContextService: RecommendationContextService? = nil,
        entitlementGate: EntitlementGate? = nil
    ) {
        lookupRepo = { owner, name in
            try await repoRepository.findByOwnerName(owner: owner, name: name)
        }
        lookupNote = { repoID in
            try await noteRepository?.find(repoId: repoID)
        }
        lookupHealth = { repoID in
            try await healthRepository?.snapshot(for: repoID)
        }
        lookupOpenSSF = { repoID in
            try await openSSFRepository?.record(for: repoID)
        }
        lookupWikiLinks = { owner, name in
            guard let wikiContextService else { return [] }
            let cached = await MainActor.run {
                let cached = wikiContextService.cachedLinks(owner: owner, repo: name)
                return cached.isEmpty ? nil : cached
            }
            if let cached { return cached }
            do {
                return try await wikiContextService.refresh(owner: owner, repo: name)
            } catch {
                return []
            }
        }
        lookupRecommendations = { repoID in
            guard let recommendationContextService else { return [] }
            if let cached = await MainActor.run(body: { recommendationContextService.cachedSnapshot(repoID: repoID) }) {
                return cached.items
            }
            return try await recommendationContextService.refresh(repoID: repoID).items
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
        lookupNote: @escaping @Sendable (Int64) async throws -> RepoNote? = { _ in nil },
        lookupHealth: @escaping @Sendable (Int64) async throws -> RepoHealthSnapshot? = { _ in nil },
        lookupOpenSSF: @escaping @Sendable (Int64) async throws -> OpenSSFScoreRecord? = { _ in nil },
        lookupWikiLinks: @escaping @Sendable (String, String) async -> [WikiLink] = { _, _ in [] },
        lookupRecommendations: @escaping @Sendable (Int64) async throws -> [RepoRecommendationItem] = { _ in [] },
        isProUser: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.lookupRepo = lookupRepo
        self.lookupNote = lookupNote
        self.lookupHealth = lookupHealth
        self.lookupOpenSSF = lookupOpenSSF
        self.lookupWikiLinks = lookupWikiLinks
        self.lookupRecommendations = lookupRecommendations
        self.isProUser = isProUser
    }

    func context(owner rawOwner: String, repo rawRepo: String) async throws -> CompanionRepoContextResponse {
        let owner = rawOwner.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = rawRepo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidGitHubPathComponent(owner), Self.isValidGitHubPathComponent(name) else {
            throw CompanionContextError.invalidRepoPath
        }

        let localRepo = try await lookupRepo(owner, name)
        let hasProEntitlement = await isProUser()
        let note = await noteDTO(for: localRepo)
        // Companion API is reachable from the browser extension, so Pro-only data
        // is cut at the local API boundary instead of relying on content-script UI
        // hiding. Private notes remain available for starred repos because they are
        // first-party local data, not one of the paid external insight surfaces.
        let health = hasProEntitlement ? await healthDTO(for: localRepo) : nil
        let openssf = hasProEntitlement ? await openSSFDTO(for: localRepo) : nil
        let wikiLinks = hasProEntitlement ? await wikiLinkDTOs(owner: owner, name: name) : []
        let recommendations = hasProEntitlement ? await recommendationDTOs(for: localRepo) : []
        let canOpenLocalActions = localRepo?.isStarred == true && hasProEntitlement
        return CompanionRepoContextResponse(
            schemaVersion: 1,
            repo: Self.repoDTO(owner: owner, name: name, localRepo: localRepo),
            recommendations: recommendations,
            wikiLinks: wikiLinks,
            note: note,
            health: health,
            openssf: openssf,
            actions: CompanionActionsDTO(
                openInStarcat: canOpenLocalActions,
                codeflow: canOpenLocalActions,
                codebase: canOpenLocalActions
            ),
            entitlement: CompanionEntitlementDTO(isPro: hasProEntitlement)
        )
    }

    private func recommendationDTOs(for repo: Repo?) async -> [CompanionRecommendationDTO] {
        guard let repo, repo.id > 0 else { return [] }
        do {
            return try await lookupRecommendations(repo.id)
                .prefix(5)
                .map { item in
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
        } catch {
            return []
        }
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

    private func noteDTO(for repo: Repo?) async -> CompanionNoteDTO? {
        guard let repo, repo.isStarred else { return nil }
        let note = try? await lookupNote(repo.id)
        return CompanionNoteDTO(
            editable: true,
            content: note?.content ?? "",
            editedAt: note?.editedAt
        )
    }

    private static func repoDTO(owner: String, name: String, localRepo: Repo?) -> CompanionRepoDTO {
        if let localRepo {
            return CompanionRepoDTO(
                owner: localRepo.owner,
                name: localRepo.name,
                fullName: localRepo.fullName,
                repoID: localRepo.id,
                htmlURL: localRepo.htmlUrl,
                knownToStarcat: true,
                isStarred: localRepo.isStarred
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
            isStarred: false
        )
    }

    private static func isValidGitHubPathComponent(_ value: String) -> Bool {
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
