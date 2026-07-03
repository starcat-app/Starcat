//
//  OpenSSFScoreServiceTests.swift
//  StarcatTests
//
//  覆盖 OpenSSFScoreService 的刷新协调语义。
//  重点验证失败分支不会破坏用户仍能看到的旧评分缓存。
//

import Testing
import Foundation
@testable import Starcat

@Suite("OpenSSF Scorecard Service", .serialized)
struct OpenSSFScoreServiceTests {
    private let baseURL = URL(string: "https://scorecard.test.invalid")!

    private func makeService() throws -> (
        OpenSSFScoreService,
        GRDBOpenSSFScoreRepository,
        GRDBRepoRepository,
        GRDBRepoNoteRepository,
        any DatabaseManaging
    ) {
        URLProtocolStub.reset()
        let db = try InMemoryDatabaseManager()
        let repository = GRDBOpenSSFScoreRepository(database: db)
        let service = OpenSSFScoreService(
            api: OpenSSFScoreAPI(baseURL: baseURL, session: URLProtocolStub.ephemeralSession()),
            repository: repository
        )
        return (
            service,
            repository,
            GRDBRepoRepository(database: db),
            GRDBRepoNoteRepository(database: db),
            db
        )
    }

    private func response(for request: URLRequest, status: Int, body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }

    private func successRecord(repoId: Int64, score: Double, fetchedAt: Date) -> OpenSSFScoreRecord {
        OpenSSFScoreRecord.success(
            repoId: repoId,
            payload: OpenSSFScorePayload(date: "2026-07-01", score: score, checks: []),
            rawData: Data(#"{"score":8.7,"checks":[]}"#.utf8),
            fetchedAt: fetchedAt
        )
    }

    @Test("刷新失败：保留旧成功评分缓存且不改变 libraryState")
    @MainActor
    func refreshFailurePreservesExistingSuccessCacheAndLibraryState() async throws {
        let (service, repository, repoRepository, noteRepository, db) = try makeService()
        try await db.insertRepoFixture(id: 42)
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE repos SET is_starred = 0, starred_at = NULL WHERE id = 42")
        }
        let repo = try #require(try await repoRepository.findById(42))
        try await noteRepository.updateLibraryState(repoId: repo.id, state: .inLibrary)
        let oldRecord = successRecord(
            repoId: repo.id,
            score: 8.7,
            fetchedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        try await repository.upsert(oldRecord)

        URLProtocolStub.requestHandler = { request in
            response(for: request, status: 500, body: #"{"message":"server error"}"#)
        }

        let refreshed = try await service.refresh(repo: repo)
        let stored = try #require(try await repository.record(for: repo.id))
        let libraryState = try await noteRepository.fetchLibraryState(repoId: repo.id)

        #expect(refreshed.fetchStatus == .success)
        #expect(refreshed.aggregateScore == 8.7)
        #expect(stored.fetchStatus == .success)
        #expect(stored.aggregateScore == 8.7)
        #expect(stored.fetchedAt == oldRecord.fetchedAt)
        #expect(libraryState == .inLibrary)
    }
}
