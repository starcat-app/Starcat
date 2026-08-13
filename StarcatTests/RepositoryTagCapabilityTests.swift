//
//  RepositoryTagCapabilityTests.swift
//  StarcatTests
//
//  标签 Capability 的 dry-run、范围校验、确认写入与 read-back 契约测试。
//

import Foundation
import Testing
@testable import Starcat

@Suite("RepositoryTagCapability")
struct RepositoryTagCapabilityTests {
    @Test("preview 规范化现有标签并生成稳定 hash")
    func previewNormalizesExistingTags() async throws {
        let source = RepositoryTagCapabilityStub(
            repos: [repo(id: 1)],
            tags: [tag(id: "swift", name: "Swift"), tag(id: "database", name: "Database")]
        )
        let executor = RepositoryTagCapabilityExecutor(source: source)

        let first = try await executor.preview(
            assignments: [RepositoryTagAssignment(repoID: 1, tagNames: ["database", "swift", "SWIFT"])],
            allowedRepoIDs: [1]
        )
        let second = try await executor.preview(
            assignments: [RepositoryTagAssignment(repoID: 1, tagNames: ["Swift", "Database"])],
            allowedRepoIDs: [1]
        )

        #expect(first.assignments == [RepositoryTagAssignment(repoID: 1, tagNames: ["Database", "Swift"])])
        #expect(first.previewHash == second.previewHash)
    }

    @Test("preview 拒绝冻结范围外或已经有标签的仓库")
    func previewRejectsOutsideScopeAndTaggedRepo() async throws {
        let existingTag = tag(id: "swift", name: "Swift")
        let source = RepositoryTagCapabilityStub(
            repos: [repo(id: 1), repo(id: 2)],
            tags: [existingTag],
            assignments: [2: [existingTag]]
        )
        let executor = RepositoryTagCapabilityExecutor(source: source)

        await #expect(throws: RepositoryTagCapabilityError.repositoriesOutsideScope([2])) {
            _ = try await executor.preview(
                assignments: [RepositoryTagAssignment(repoID: 2, tagNames: ["Swift"])],
                allowedRepoIDs: [1]
            )
        }
        await #expect(throws: RepositoryTagCapabilityError.repositoryAlreadyTagged(2)) {
            _ = try await executor.preview(
                assignments: [RepositoryTagAssignment(repoID: 2, tagNames: ["Swift"])],
                allowedRepoIDs: [2]
            )
        }
    }

    @Test("apply 校验 preview hash 后批量写入并 read-back")
    func applyWritesAndReadsBack() async throws {
        let source = RepositoryTagCapabilityStub(
            repos: [repo(id: 1), repo(id: 2)],
            tags: [tag(id: "swift", name: "Swift")]
        )
        let executor = RepositoryTagCapabilityExecutor(source: source)
        let assignments = [
            RepositoryTagAssignment(repoID: 1, tagNames: ["Swift"]),
            RepositoryTagAssignment(repoID: 2, tagNames: ["Swift"])
        ]
        let preview = try await executor.preview(assignments: assignments, allowedRepoIDs: [1, 2])

        let result = try await executor.apply(
            assignments: assignments,
            expectedPreviewHash: preview.previewHash,
            allowedRepoIDs: [1, 2]
        )

        #expect(result.verifiedTagNamesByRepoID[1] == ["Swift"])
        #expect(result.verifiedTagNamesByRepoID[2] == ["Swift"])
        #expect(await source.recordedWrites() == [RepositoryTagWrite(tagID: "swift", repoIDs: [1, 2])])
        #expect(await source.mutationCount() == 2)
    }

    @Test("apply 拒绝与最新 dry-run 不一致的 hash")
    func applyRejectsChangedPreview() async {
        let source = RepositoryTagCapabilityStub(
            repos: [repo(id: 1)],
            tags: [tag(id: "swift", name: "Swift")]
        )
        let executor = RepositoryTagCapabilityExecutor(source: source)

        await #expect(throws: RepositoryTagCapabilityError.previewChanged) {
            _ = try await executor.apply(
                assignments: [RepositoryTagAssignment(repoID: 1, tagNames: ["Swift"])],
                expectedPreviewHash: "stale",
                allowedRepoIDs: [1]
            )
        }
        #expect(await source.recordedWrites().isEmpty)
    }

    @Test("Untagged Tidy adapter 将 preview 保持只读并把 apply 标记为确认写入")
    func agentToolsExposeApprovalBoundary() async throws {
        let source = RepositoryTagCapabilityStub(
            repos: [repo(id: 1)],
            tags: [tag(id: "swift", name: "Swift")]
        )
        let tools = UntaggedTidyAgentTools.make(
            executor: RepositoryTagCapabilityExecutor(source: source)
        )
        let registry = try AgentToolRegistry(tools: tools)
        let previewTool = try registry.tool(named: "tag_preview_untagged")
        let applyTool = try registry.tool(named: "tag_apply_untagged")
        let context = AgentRunContext(
            sourceDescription: "Explicit Selection",
            repos: [snapshot(id: 1)]
        )

        let preview = await previewTool.execute(AgentToolInput(
            arguments: assignmentArguments(repoID: 1, tagName: "Swift"),
            prompt: "整理标签",
            context: context
        ))

        #expect(previewTool.permission == .readOnly)
        #expect(applyTool.permission == .requiresConfirmation)
        #expect(applyTool.definition.completesRun)
        #expect(preview.status == .completed)
        #expect(preview.output.output.contains("dry_run: true"))
        #expect(preview.output.output.contains("preview_hash:"))
    }

    @Test("通用标签能力复用 create、add、remove 与 replace 领域写入")
    func mutationCapabilityCoversPublishedMCPTagSemantics() async throws {
        let source = RepositoryTagCapabilityStub(
            repos: [repo(id: 1)],
            tags: [tag(id: "swift", name: "Swift")]
        )
        let executor = RepositoryTagCapabilityExecutor(source: source)

        let dryRun = try await executor.addTags(
            repoID: 1,
            tagNames: ["AI"],
            createMissing: true,
            dryRun: true
        )
        #expect(dryRun.changed == false)
        #expect(await source.tagNames() == ["Swift"])

        _ = try await executor.addTags(
            repoID: 1,
            tagNames: ["Swift", "AI"],
            createMissing: true,
            dryRun: false
        )
        #expect(Set(await source.assignedTagNames(repoID: 1)) == ["AI", "Swift"])

        _ = try await executor.removeTags(repoID: 1, tagNames: ["Swift"], dryRun: false)
        #expect(await source.assignedTagNames(repoID: 1) == ["AI"])

        let replacement = try await executor.replaceTags(
            repoID: 1,
            tagNames: ["Swift"],
            createMissing: false,
            dryRun: false
        )
        #expect(replacement.warnings == ["This replaces all existing tags on the repository."])
        #expect(await source.assignedTagNames(repoID: 1) == ["Swift"])
        #expect(await source.mutationCount() == 3)
    }

    private func repo(id: Int64) -> Repo {
        var repo = Repo.makeMinimal(owner: "octo", name: "repo-\(id)")
        repo.id = id
        repo.isStarred = true
        return repo
    }

    private func tag(id: String, name: String) -> Starcat.Tag {
        Starcat.Tag(
            id: id,
            name: name,
            color: nil,
            icon: nil,
            sortOrder: 0,
            isPreset: false,
            parentId: nil,
            createdAt: "2026-08-10T00:00:00Z",
            updatedAt: "2026-08-10T00:00:00Z"
        )
    }

    private func snapshot(id: Int64) -> AgentRepoSnapshot {
        AgentRepoSnapshot(
            id: id,
            owner: "octo",
            name: "repo-\(id)",
            fullName: "octo/repo-\(id)",
            description: "Demo",
            language: "Swift",
            starsCount: 1,
            topics: [],
            isPrivate: false,
            isStarred: true,
            starredAt: nil,
            htmlUrl: "https://github.com/octo/repo-\(id)"
        )
    }

    private func assignmentArguments(repoID: Int64, tagName: String) -> AgentJSONValue {
        .object([
            "assignments": .array([.object([
                "repoID": .number(Double(repoID)),
                "tagNames": .array([.string(tagName)])
            ])])
        ])
    }
}

private struct RepositoryTagWrite: Equatable, Sendable {
    var tagID: String
    var repoIDs: [Int64]
}

private actor RepositoryTagCapabilityStub: RepositoryTagMutationCapabilitySource {
    private let reposByID: [Int64: Repo]
    private var tags: [Starcat.Tag]
    private var assignments: [Int64: [Starcat.Tag]]
    private var writes: [RepositoryTagWrite] = []
    private var repositoryMutationCount = 0

    init(repos: [Repo], tags: [Starcat.Tag], assignments: [Int64: [Starcat.Tag]] = [:]) {
        self.reposByID = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0) })
        self.tags = tags
        self.assignments = assignments
    }

    func findRepository(id: Int64) -> Repo? { reposByID[id] }

    func fetchAllTags() -> [Starcat.Tag] { tags }

    func fetchTags(repoID: Int64) -> [Starcat.Tag] { assignments[repoID, default: []] }

    func batchAddTag(repoIDs: [Int64], tagID: String) throws {
        guard let tag = tags.first(where: { $0.id == tagID }) else {
            throw RepositoryTagCapabilityError.tagNotFound(tagID)
        }
        writes.append(RepositoryTagWrite(tagID: tagID, repoIDs: repoIDs.sorted()))
        for repoID in repoIDs where !assignments[repoID, default: []].contains(where: { $0.id == tagID }) {
            assignments[repoID, default: []].append(tag)
        }
    }

    func findTag(name: String) -> Starcat.Tag? {
        tags.first { $0.name == name }
    }

    func createTag(_ tag: Starcat.Tag) {
        tags.append(tag)
    }

    func addTag(repoID: Int64, tagID: String) throws {
        try batchAddTag(repoIDs: [repoID], tagID: tagID)
    }

    func removeTag(repoID: Int64, tagID: String) {
        assignments[repoID, default: []].removeAll { $0.id == tagID }
    }

    func replaceTags(repoID: Int64, tagIDs: [String]) throws {
        let resolved = try tagIDs.map { tagID in
            guard let tag = tags.first(where: { $0.id == tagID }) else {
                throw RepositoryTagMutationCapabilityError.tagNotFound(tagID)
            }
            return tag
        }
        assignments[repoID] = resolved
    }

    func didMutateRepository(_ repository: Repo) {
        repositoryMutationCount += 1
    }

    func recordedWrites() -> [RepositoryTagWrite] { writes }

    func tagNames() -> [String] { tags.map(\.name).sorted() }

    func assignedTagNames(repoID: Int64) -> [String] {
        assignments[repoID, default: []].map(\.name).sorted()
    }

    func mutationCount() -> Int { repositoryMutationCount }
}
