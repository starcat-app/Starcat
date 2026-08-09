//
//  RepositoryTagCapability.swift
//  Starcat
//
//  仓库标签建议与确认写入的统一能力层。
//
//  Agent 和 MCP 最终都应复用这里的领域语义：调用方提供明确仓库范围，Executor 先生成
//  可审计 dry-run，再以同一 preview hash 执行写入并 read-back。该层不依赖 Agent Runtime、
//  MCP SDK、listener 或 UI，审批由上层 adapter 按各自协议完成。
//

import CryptoKit
import Foundation

enum RepositoryTagCapabilities {
    static let preview = StarcatCapabilityDefinition(
        id: "repository.tags.preview",
        summary: "Validate existing-tag assignments and produce a deterministic dry-run.",
        permission: .readOnly
    )

    static let apply = StarcatCapabilityDefinition(
        id: "repository.tags.apply",
        summary: "Apply a previously previewed tag diff and verify persisted assignments.",
        permission: .requiresConfirmation
    )
}

struct RepositoryTagAssignment: Codable, Hashable, Sendable {
    var repoID: Int64
    var tagNames: [String]
}

struct RepositoryTagInspection: Sendable {
    var repositories: [Repo]
    var availableTags: [Tag]
    var currentTagsByRepoID: [Int64: [Tag]]
}

struct RepositoryTagPreview: Codable, Hashable, Sendable {
    var assignments: [RepositoryTagAssignment]
    var previewHash: String
}

struct RepositoryTagApplyResult: Sendable {
    var preview: RepositoryTagPreview
    var verifiedTagNamesByRepoID: [Int64: [String]]
}

protocol RepositoryTagCapabilitySource: Sendable {
    func findRepository(id: Int64) async throws -> Repo?
    func fetchAllTags() async throws -> [Tag]
    func fetchTags(repoID: Int64) async throws -> [Tag]
    func batchAddTag(repoIDs: [Int64], tagID: String) async throws
}

protocol RepositoryTagCapabilityExecuting: Sendable {
    func inspect(repoIDs: [Int64], allowedRepoIDs: Set<Int64>) async throws -> RepositoryTagInspection
    func preview(
        assignments: [RepositoryTagAssignment],
        allowedRepoIDs: Set<Int64>
    ) async throws -> RepositoryTagPreview
    func apply(
        assignments: [RepositoryTagAssignment],
        expectedPreviewHash: String,
        allowedRepoIDs: Set<Int64>
    ) async throws -> RepositoryTagApplyResult
}

struct DatabaseRepositoryTagCapabilitySource: RepositoryTagCapabilitySource {
    let repoRepository: any RepoRepositoryProtocol
    let tagRepository: any TagRepositoryProtocol
    let repoTagRepository: any RepoTagRepositoryProtocol

    func findRepository(id: Int64) async throws -> Repo? {
        try await repoRepository.findById(id)
    }

    func fetchAllTags() async throws -> [Tag] {
        try await tagRepository.fetchAll()
    }

    func fetchTags(repoID: Int64) async throws -> [Tag] {
        try await repoTagRepository.fetchTags(forRepo: repoID)
    }

    func batchAddTag(repoIDs: [Int64], tagID: String) async throws {
        try await repoTagRepository.batchAddTag(repoIds: repoIDs, tagId: tagID)
    }
}

/// 标签写入的唯一领域执行器。
///
/// 第一版只允许复用已有标签，避免模型在一次批量操作中扩张用户 taxonomy。写入前再次
/// 运行 preview，因此仓库范围、未打标签状态、标签存在性和 preview hash 都会重新校验。
struct RepositoryTagCapabilityExecutor<Source: RepositoryTagCapabilitySource>: RepositoryTagCapabilityExecuting, Sendable {
    let source: Source

    func inspect(repoIDs: [Int64], allowedRepoIDs: Set<Int64>) async throws -> RepositoryTagInspection {
        let normalizedRepoIDs = try validateRepoIDs(repoIDs, allowedRepoIDs: allowedRepoIDs)
        var repositories: [Repo] = []
        var currentTagsByRepoID: [Int64: [Tag]] = [:]
        for repoID in normalizedRepoIDs {
            guard let repo = try await source.findRepository(id: repoID) else {
                throw RepositoryTagCapabilityError.repositoryNotLocal(repoID)
            }
            repositories.append(repo)
            currentTagsByRepoID[repoID] = try await source.fetchTags(repoID: repoID)
        }
        return RepositoryTagInspection(
            repositories: repositories,
            availableTags: try await source.fetchAllTags(),
            currentTagsByRepoID: currentTagsByRepoID
        )
    }

    func preview(
        assignments: [RepositoryTagAssignment],
        allowedRepoIDs: Set<Int64>
    ) async throws -> RepositoryTagPreview {
        guard !assignments.isEmpty else {
            throw RepositoryTagCapabilityError.emptyAssignments
        }
        let normalized = try normalize(assignments)
        let inspection = try await inspect(
            repoIDs: normalized.map(\.repoID),
            allowedRepoIDs: allowedRepoIDs
        )
        let tagsByName = Dictionary(
            uniqueKeysWithValues: inspection.availableTags.map { ($0.name.lowercased(), $0) }
        )
        for assignment in normalized {
            let current = inspection.currentTagsByRepoID[assignment.repoID] ?? []
            guard current.isEmpty else {
                throw RepositoryTagCapabilityError.repositoryAlreadyTagged(assignment.repoID)
            }
            for tagName in assignment.tagNames where tagsByName[tagName.lowercased()] == nil {
                throw RepositoryTagCapabilityError.tagNotFound(tagName)
            }
        }
        let canonical = normalized.map { assignment in
            RepositoryTagAssignment(
                repoID: assignment.repoID,
                tagNames: assignment.tagNames.map { tagsByName[$0.lowercased()]!.name }
            )
        }
        return RepositoryTagPreview(
            assignments: canonical,
            previewHash: try previewHash(assignments: canonical)
        )
    }

    func apply(
        assignments: [RepositoryTagAssignment],
        expectedPreviewHash: String,
        allowedRepoIDs: Set<Int64>
    ) async throws -> RepositoryTagApplyResult {
        let preview = try await preview(assignments: assignments, allowedRepoIDs: allowedRepoIDs)
        guard preview.previewHash == expectedPreviewHash else {
            throw RepositoryTagCapabilityError.previewChanged
        }
        let availableTags = try await source.fetchAllTags()
        let tagsByName = Dictionary(uniqueKeysWithValues: availableTags.map { ($0.name.lowercased(), $0) })
        var repoIDsByTagID: [String: [Int64]] = [:]
        for assignment in preview.assignments {
            for tagName in assignment.tagNames {
                guard let tag = tagsByName[tagName.lowercased()] else {
                    throw RepositoryTagCapabilityError.tagNotFound(tagName)
                }
                repoIDsByTagID[tag.id, default: []].append(assignment.repoID)
            }
        }
        // 固定写入顺序，避免同一预览因 Dictionary 遍历顺序不同而产生不可复现的审计轨迹。
        for tagID in repoIDsByTagID.keys.sorted() {
            guard let repoIDs = repoIDsByTagID[tagID] else { continue }
            try await source.batchAddTag(repoIDs: repoIDs.sorted(), tagID: tagID)
        }

        var verified: [Int64: [String]] = [:]
        for assignment in preview.assignments {
            let persistedNames = try await source.fetchTags(repoID: assignment.repoID).map(\.name)
            let persistedSet = Set(persistedNames.map { $0.lowercased() })
            let expectedSet = Set(assignment.tagNames.map { $0.lowercased() })
            guard expectedSet.isSubset(of: persistedSet) else {
                throw RepositoryTagCapabilityError.readBackMismatch(assignment.repoID)
            }
            verified[assignment.repoID] = persistedNames
        }
        return RepositoryTagApplyResult(preview: preview, verifiedTagNamesByRepoID: verified)
    }

    private func validateRepoIDs(
        _ repoIDs: [Int64],
        allowedRepoIDs: Set<Int64>
    ) throws -> [Int64] {
        var seenRepoIDs: Set<Int64> = []
        let normalized = repoIDs.filter { seenRepoIDs.insert($0).inserted }
        guard !normalized.isEmpty else { throw RepositoryTagCapabilityError.emptyAssignments }
        guard normalized.count <= 30 else { throw RepositoryTagCapabilityError.tooManyRepositories }
        let outsideScope = normalized.filter { !allowedRepoIDs.contains($0) }
        guard outsideScope.isEmpty else {
            throw RepositoryTagCapabilityError.repositoriesOutsideScope(outsideScope)
        }
        return normalized
    }

    private func normalize(_ assignments: [RepositoryTagAssignment]) throws -> [RepositoryTagAssignment] {
        let repoIDs = assignments.map(\.repoID)
        guard Set(repoIDs).count == repoIDs.count else {
            throw RepositoryTagCapabilityError.duplicateRepositoryAssignment
        }
        return try assignments.map { assignment in
            var seenNames: Set<String> = []
            let names = assignment.tagNames
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seenNames.insert($0.lowercased()).inserted }
            guard !names.isEmpty else {
                throw RepositoryTagCapabilityError.emptyTags(assignment.repoID)
            }
            guard names.count <= 8 else {
                throw RepositoryTagCapabilityError.tooManyTags(assignment.repoID)
            }
            return RepositoryTagAssignment(repoID: assignment.repoID, tagNames: names.sorted())
        }.sorted { $0.repoID < $1.repoID }
    }

    private func previewHash(assignments: [RepositoryTagAssignment]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(assignments))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum RepositoryTagCapabilityError: LocalizedError, Equatable, Sendable {
    case emptyAssignments
    case tooManyRepositories
    case repositoriesOutsideScope([Int64])
    case repositoryNotLocal(Int64)
    case repositoryAlreadyTagged(Int64)
    case duplicateRepositoryAssignment
    case emptyTags(Int64)
    case tooManyTags(Int64)
    case tagNotFound(String)
    case previewChanged
    case readBackMismatch(Int64)

    var errorDescription: String? {
        switch self {
        case .emptyAssignments: return "At least one repository tag assignment is required."
        case .tooManyRepositories: return "A tag operation can include at most 30 repositories."
        case .repositoriesOutsideScope(let ids): return "Repository IDs are outside the approved scope: \(ids)."
        case .repositoryNotLocal(let id): return "Repository \(id) is not stored in the local repos table and cannot be tagged."
        case .repositoryAlreadyTagged(let id): return "Repository \(id) is no longer untagged. Refresh the preview."
        case .duplicateRepositoryAssignment: return "Each repository may appear only once in the tag diff."
        case .emptyTags(let id): return "Repository \(id) must have at least one suggested tag."
        case .tooManyTags(let id): return "Repository \(id) may receive at most 8 tags in one operation."
        case .tagNotFound(let name): return "Existing tag not found: \(name)."
        case .previewChanged: return "The approved tag diff no longer matches the latest dry-run preview."
        case .readBackMismatch(let id): return "Tag read-back verification failed for repository \(id)."
        }
    }
}
