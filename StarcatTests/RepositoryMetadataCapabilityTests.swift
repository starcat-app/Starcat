//
//  RepositoryMetadataCapabilityTests.swift
//  StarcatTests
//
//  仓库笔记与状态共享 Capability 的 dry-run、写后回读和副作用契约测试。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("RepositoryMetadataCapability")
struct RepositoryMetadataCapabilityTests {
    @Test("笔记 dry-run 不写库，真实写入后回读并触发刷新")
    func noteDryRunAndWriteBack() async throws {
        let db = try InMemoryDatabaseManager()
        try await db.insertRepoFixture(id: 1)
        let noteRepository = GRDBRepoNoteRepository(database: db)
        let recorder = RepositoryMetadataMutationRecorder()
        let executor = makeExecutor(
            database: db,
            noteRepository: noteRepository,
            recorder: recorder
        )

        let dryRun = try await executor.upsertNote(repoID: 1, content: "preview", dryRun: true)
        #expect(dryRun.changed == false)
        #expect(dryRun.note == nil)
        #expect(try await noteRepository.find(repoId: 1) == nil)
        #expect(recorder.mutations.isEmpty)

        let written = try await executor.upsertNote(repoID: 1, content: "shared capability", dryRun: false)
        #expect(written.changed)
        #expect(written.note?.content == "shared capability")
        #expect(try await noteRepository.find(repoId: 1)?.content == "shared capability")
        #expect(recorder.mutations == ["note"])
    }

    @Test("状态写入回读最终值并把状态副作用交给 source adapter")
    func statusWritesAndReportsMutation() async throws {
        let db = try InMemoryDatabaseManager()
        try await db.insertRepoFixture(id: 1)
        let noteRepository = GRDBRepoNoteRepository(database: db)
        let recorder = RepositoryMetadataMutationRecorder()
        let executor = makeExecutor(
            database: db,
            noteRepository: noteRepository,
            recorder: recorder
        )

        let result = try await executor.setStatus(repoID: 1, status: .using, dryRun: false)

        #expect(result.note?.status == RepoStatus.using.rawValue)
        #expect(try await noteRepository.find(repoId: 1)?.status == RepoStatus.using.rawValue)
        #expect(recorder.mutations == ["status:using"])
    }

    private func makeExecutor(
        database: any DatabaseManaging,
        noteRepository: any RepoNoteRepositoryProtocol,
        recorder: RepositoryMetadataMutationRecorder
    ) -> RepositoryMetadataCapabilityExecutor<DatabaseRepositoryMetadataCapabilitySource> {
        RepositoryMetadataCapabilityExecutor(
            source: DatabaseRepositoryMetadataCapabilitySource(
                repoRepository: GRDBRepoRepository(database: database),
                repoNoteRepository: noteRepository,
                onRepositoryMutation: { _, mutation in
                    switch mutation {
                    case .note:
                        recorder.mutations.append("note")
                    case .status(let status):
                        recorder.mutations.append("status:\(status.rawValue)")
                    }
                }
            )
        )
    }
}

@MainActor
private final class RepositoryMetadataMutationRecorder {
    var mutations: [String] = []
}
