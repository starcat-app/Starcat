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

    static let create = StarcatCapabilityDefinition(
        id: "repository.tags.create",
        summary: "Create one local repository tag.",
        permission: .requiresConfirmation
    )

    static let add = StarcatCapabilityDefinition(
        id: "repository.tags.add",
        summary: "Add local tags to one repository.",
        permission: .requiresConfirmation
    )

    static let remove = StarcatCapabilityDefinition(
        id: "repository.tags.remove",
        summary: "Remove local tags from one repository.",
        permission: .requiresConfirmation
    )

    static let replace = StarcatCapabilityDefinition(
        id: "repository.tags.replace",
        summary: "Replace all local tags on one repository.",
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

struct RepositoryTagMutationResult: Sendable {
    var repository: Repo?
    var tags: [Tag]
    var changed: Bool
    var warnings: [String]
}

protocol RepositoryTagCapabilitySource: Sendable {
    func findRepository(id: Int64) async throws -> Repo?
    func fetchAllTags() async throws -> [Tag]
    func fetchTags(repoID: Int64) async throws -> [Tag]
    func batchAddTag(repoIDs: [Int64], tagID: String) async throws
    func didMutateRepository(_ repository: Repo) async
}

extension RepositoryTagCapabilitySource {
    /// 纯内存测试源或无需派生缓存的调用方可以 no-op；数据库源会刷新语义索引。
    func didMutateRepository(_ repository: Repo) async {}
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

/// MCP 与后续 Agent 写工具共用的标签变更表面。
///
/// `dryRun` 属于能力输入而不是 MCP 特例：任何 adapter 都必须能先得到确定性结果，再决定
/// 是否申请审批。设置开关、Pro entitlement 和外部协议错误仍由各 adapter 自己负责。
protocol RepositoryTagMutationCapabilityExecuting: Sendable {
    func createTag(name: String, color: String?, icon: String?, dryRun: Bool) async throws -> RepositoryTagMutationResult
    func addTags(repoID: Int64, tagNames: [String], createMissing: Bool, dryRun: Bool) async throws -> RepositoryTagMutationResult
    func removeTags(repoID: Int64, tagNames: [String], dryRun: Bool) async throws -> RepositoryTagMutationResult
    func replaceTags(repoID: Int64, tagNames: [String], createMissing: Bool, dryRun: Bool) async throws -> RepositoryTagMutationResult
}

protocol RepositoryTagMutationCapabilitySource: RepositoryTagCapabilitySource {
    func findTag(name: String) async throws -> Tag?
    func createTag(_ tag: Tag) async throws
    func addTag(repoID: Int64, tagID: String) async throws
    func removeTag(repoID: Int64, tagID: String) async throws
    func replaceTags(repoID: Int64, tagIDs: [String]) async throws
}

struct DatabaseRepositoryTagCapabilitySource: RepositoryTagMutationCapabilitySource {
    let repoRepository: any RepoRepositoryProtocol
    let tagRepository: any TagRepositoryProtocol
    let repoTagRepository: any RepoTagRepositoryProtocol
    let onRepositoryMutation: @MainActor @Sendable (Repo) async -> Void

    init(
        repoRepository: any RepoRepositoryProtocol,
        tagRepository: any TagRepositoryProtocol,
        repoTagRepository: any RepoTagRepositoryProtocol,
        onRepositoryMutation: @escaping @MainActor @Sendable (Repo) async -> Void = { _ in }
    ) {
        self.repoRepository = repoRepository
        self.tagRepository = tagRepository
        self.repoTagRepository = repoTagRepository
        self.onRepositoryMutation = onRepositoryMutation
    }

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

    func findTag(name: String) async throws -> Tag? {
        try await tagRepository.findByName(name)
    }

    func createTag(_ tag: Tag) async throws {
        try await tagRepository.create(tag)
    }

    func addTag(repoID: Int64, tagID: String) async throws {
        try await repoTagRepository.addTag(repoId: repoID, tagId: tagID)
    }

    func removeTag(repoID: Int64, tagID: String) async throws {
        try await repoTagRepository.removeTag(repoId: repoID, tagId: tagID)
    }

    func replaceTags(repoID: Int64, tagIDs: [String]) async throws {
        try await repoTagRepository.setTags(repoId: repoID, tagIds: tagIDs)
    }

    func didMutateRepository(_ repository: Repo) async {
        await onRepositoryMutation(repository)
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
        var mutatedRepositories: [Repo] = []
        for assignment in preview.assignments {
            let persistedNames = try await source.fetchTags(repoID: assignment.repoID).map(\.name)
            let persistedSet = Set(persistedNames.map { $0.lowercased() })
            let expectedSet = Set(assignment.tagNames.map { $0.lowercased() })
            guard expectedSet.isSubset(of: persistedSet) else {
                throw RepositoryTagCapabilityError.readBackMismatch(assignment.repoID)
            }
            verified[assignment.repoID] = persistedNames
            guard let repository = try await source.findRepository(id: assignment.repoID) else {
                throw RepositoryTagCapabilityError.repositoryNotLocal(assignment.repoID)
            }
            mutatedRepositories.append(repository)
        }
        // 所有仓库都通过 read-back 后再刷新派生缓存，避免半成功批次被展示成完整结果。
        for repository in mutatedRepositories {
            await source.didMutateRepository(repository)
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

extension RepositoryTagCapabilityExecutor: RepositoryTagMutationCapabilityExecuting where Source: RepositoryTagMutationCapabilitySource {
    func createTag(
        name: String,
        color: String?,
        icon: String?,
        dryRun: Bool
    ) async throws -> RepositoryTagMutationResult {
        let normalized = try normalizeTagName(name)
        if let existing = try await source.findTag(name: normalized) {
            return RepositoryTagMutationResult(
                repository: nil,
                tags: [existing],
                changed: false,
                warnings: ["Tag already exists."]
            )
        }
        let now = ISO8601DateFormatter.shared.string(from: Date())
        let tag = Tag(
            id: UUID().uuidString,
            name: normalized,
            color: normalizedOptional(color),
            icon: normalizedOptional(icon),
            sortOrder: 0,
            isPreset: false,
            parentId: nil,
            createdAt: now,
            updatedAt: now
        )
        if !dryRun {
            try await source.createTag(tag)
            guard try await source.findTag(name: normalized)?.id == tag.id else {
                throw RepositoryTagMutationCapabilityError.readBackMismatch("tag \(normalized)")
            }
        }
        return RepositoryTagMutationResult(
            repository: nil,
            tags: [tag],
            changed: !dryRun,
            warnings: []
        )
    }

    func addTags(
        repoID: Int64,
        tagNames: [String],
        createMissing: Bool,
        dryRun: Bool
    ) async throws -> RepositoryTagMutationResult {
        let repository = try await requireRepository(repoID)
        let tags = try await resolveTags(names: tagNames, createMissing: createMissing, dryRun: dryRun)
        if !dryRun {
            for tag in tags {
                try await source.addTag(repoID: repoID, tagID: tag.id)
            }
            try await verifyAdded(tags, repoID: repoID)
            await source.didMutateRepository(repository)
        }
        return RepositoryTagMutationResult(
            repository: repository,
            tags: tags,
            changed: !dryRun && !tags.isEmpty,
            warnings: []
        )
    }

    func removeTags(
        repoID: Int64,
        tagNames: [String],
        dryRun: Bool
    ) async throws -> RepositoryTagMutationResult {
        let repository = try await requireRepository(repoID)
        let tags = try await existingTags(names: tagNames)
        if !dryRun {
            for tag in tags {
                try await source.removeTag(repoID: repoID, tagID: tag.id)
            }
            try await verifyRemoved(tags, repoID: repoID)
            await source.didMutateRepository(repository)
        }
        return RepositoryTagMutationResult(
            repository: repository,
            tags: tags,
            changed: !dryRun && !tags.isEmpty,
            warnings: []
        )
    }

    func replaceTags(
        repoID: Int64,
        tagNames: [String],
        createMissing: Bool,
        dryRun: Bool
    ) async throws -> RepositoryTagMutationResult {
        let repository = try await requireRepository(repoID)
        let tags = try await resolveTags(names: tagNames, createMissing: createMissing, dryRun: dryRun)
        if !dryRun {
            try await source.replaceTags(repoID: repoID, tagIDs: tags.map(\.id))
            try await verifyReplacement(tags, repoID: repoID)
            await source.didMutateRepository(repository)
        }
        return RepositoryTagMutationResult(
            repository: repository,
            tags: tags,
            changed: !dryRun,
            warnings: ["This replaces all existing tags on the repository."]
        )
    }

    private func requireRepository(_ repoID: Int64) async throws -> Repo {
        guard let repository = try await source.findRepository(id: repoID) else {
            throw RepositoryTagMutationCapabilityError.repositoryNotLocal(repoID)
        }
        return repository
    }

    private func resolveTags(names: [String], createMissing: Bool, dryRun: Bool) async throws -> [Tag] {
        let normalizedNames = try normalizeTagNames(names)
        var tags: [Tag] = []
        for name in normalizedNames {
            if let existing = try await source.findTag(name: name) {
                tags.append(existing)
                continue
            }
            guard createMissing else {
                throw RepositoryTagMutationCapabilityError.tagNotFound(name)
            }
            let now = ISO8601DateFormatter.shared.string(from: Date())
            let tag = Tag(
                id: UUID().uuidString,
                name: name,
                color: nil,
                icon: nil,
                sortOrder: 0,
                isPreset: false,
                parentId: nil,
                createdAt: now,
                updatedAt: now
            )
            if !dryRun {
                try await source.createTag(tag)
            }
            tags.append(tag)
        }
        return tags
    }

    private func existingTags(names: [String]) async throws -> [Tag] {
        var tags: [Tag] = []
        for name in try normalizeTagNames(names) {
            if let tag = try await source.findTag(name: name) {
                tags.append(tag)
            }
        }
        return tags
    }

    private func normalizeTagNames(_ names: [String]) throws -> [String] {
        let normalized = Array(Set(try names.map(normalizeTagName))).sorted()
        guard !normalized.isEmpty else {
            throw RepositoryTagMutationCapabilityError.emptyTagNames
        }
        return normalized
    }

    private func normalizeTagName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RepositoryTagMutationCapabilityError.emptyTagName
        }
        return trimmed
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func verifyAdded(_ tags: [Tag], repoID: Int64) async throws {
        let persistedIDs = Set(try await source.fetchTags(repoID: repoID).map(\.id))
        guard Set(tags.map(\.id)).isSubset(of: persistedIDs) else {
            throw RepositoryTagMutationCapabilityError.readBackMismatch("repository \(repoID) add")
        }
    }

    private func verifyRemoved(_ tags: [Tag], repoID: Int64) async throws {
        let persistedIDs = Set(try await source.fetchTags(repoID: repoID).map(\.id))
        guard Set(tags.map(\.id)).isDisjoint(with: persistedIDs) else {
            throw RepositoryTagMutationCapabilityError.readBackMismatch("repository \(repoID) remove")
        }
    }

    private func verifyReplacement(_ tags: [Tag], repoID: Int64) async throws {
        let persistedIDs = Set(try await source.fetchTags(repoID: repoID).map(\.id))
        guard persistedIDs == Set(tags.map(\.id)) else {
            throw RepositoryTagMutationCapabilityError.readBackMismatch("repository \(repoID) replace")
        }
    }
}

enum RepositoryTagMutationCapabilityError: LocalizedError, Equatable, Sendable {
    case repositoryNotLocal(Int64)
    case emptyTagName
    case emptyTagNames
    case tagNotFound(String)
    case readBackMismatch(String)

    var errorDescription: String? {
        switch self {
        case .repositoryNotLocal(let repoID): return "Repository not found: \(repoID)"
        case .emptyTagName: return "Tag name cannot be empty."
        case .emptyTagNames: return "Provide at least one tag name."
        case .tagNotFound(let name): return "Tag not found: \(name)"
        case .readBackMismatch(let operation): return "Tag read-back verification failed for \(operation)."
        }
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
