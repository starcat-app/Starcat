//
//  AIOrganizationDraftRepositoryTests.swift
//  StarcatTests
//
//  验证手动 AI 整理草稿的事务建档、逐仓更新与级联清理。
//

import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("AI organization draft repository")
struct AIOrganizationDraftRepositoryTests {

    @Test("恢复时把执行中状态收口为可重试中断失败")
    func normalizesInterruptedStates() {
        var repo = Repo.makeMinimal(owner: "octo", name: "draft")
        repo.id = 42
        var tagJob = BatchAIJob(repoId: repo.id, repoFullName: repo.fullName)
        tagJob.status = .processing
        tagJob.tagReviewState = .applying
        let restoredTagJob = BatchAIOrganizationDraftItem(
            repo: repo,
            job: tagJob,
            isSelectedForTagApplication: true
        ).restoredJob()
        #expect(restoredTagJob.status == .failed)
        #expect(restoredTagJob.failure == .interrupted)
        #expect(restoredTagJob.tagReviewState == .failed(.interrupted))

        let groupingJob = GitHubStarListAIGroupingJob(
            repo: repo,
            status: .analyzing,
            applyState: .applying
        )
        let restoredGroupingJob = GitHubStarListAIOrganizationDraftItem(
            job: groupingJob,
            existingListIDs: [],
            selectedListIDs: ["list-1"],
            isSelectedForBulkApply: true,
            editedListIDs: nil,
            isIgnored: false
        ).restoredJob()
        #expect(restoredGroupingJob.status == .failed)
        #expect(restoredGroupingJob.analysisFailure == .interrupted)
        #expect(restoredGroupingJob.applyState == .failed(.init(kind: .interrupted, detail: nil)))
    }

    @Test("同类草稿原子替换并逐仓更新")
    func replaceAndUpdateItems() async throws {
        let database = try InMemoryDatabaseManager(userId: 1)
        let repository = GRDBAIOrganizationDraftRepository(database: database)
        let draftID = UUID()
        try await repository.replaceDraft(AIOrganizationDraft(
            id: draftID,
            kind: .batchTags,
            headerJSON: #"{"version":1}"#,
            items: [
                AIOrganizationDraftItem(repoID: 1, payloadJSON: #"{"status":"queued"}"#),
                AIOrganizationDraftItem(repoID: 2, payloadJSON: #"{"status":"queued"}"#),
            ]
        ))

        try await repository.upsertItem(
            draftID: draftID,
            kind: .batchTags,
            repoID: 1,
            payloadJSON: #"{"status":"completed"}"#
        )
        try await repository.deleteItems(draftID: draftID, kind: .batchTags, repoIDs: [2])

        let restored = try #require(try await repository.loadDraft(kind: .batchTags))
        #expect(restored.id == draftID)
        #expect(restored.items == [
            AIOrganizationDraftItem(repoID: 1, payloadJSON: #"{"status":"completed"}"#)
        ])
    }

    @Test("删除 Header 会级联清理逐仓 Item")
    func deleteDraftCascadesItems() async throws {
        let database = try InMemoryDatabaseManager(userId: 1)
        let repository = GRDBAIOrganizationDraftRepository(database: database)
        let draftID = UUID()
        try await repository.replaceDraft(AIOrganizationDraft(
            id: draftID,
            kind: .githubStarLists,
            headerJSON: "{}",
            items: [AIOrganizationDraftItem(repoID: 7, payloadJSON: "{}")]
        ))

        try await repository.deleteDraft(draftID: draftID, kind: .githubStarLists)

        #expect(try await repository.loadDraft(kind: .githubStarLists) == nil)
        let itemCount = try await database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ai_organization_draft_items") ?? -1
        }
        #expect(itemCount == 0)
    }
}
