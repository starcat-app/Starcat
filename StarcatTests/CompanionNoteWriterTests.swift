//
//  CompanionNoteWriterTests.swift
//  StarcatTests
//
//  验证 Chrome Companion 私人笔记写入规则。
//

import Foundation
import Testing
@testable import Starcat

@Suite("CompanionNoteWriter")
struct CompanionNoteWriterTests {

    @Test("starred repo can update note content")
    func starredRepoCanUpdateNote() async throws {
        let recorder = CompanionNoteUpdateRecorder()
        let writer = CompanionNoteWriter(
            lookupRepo: { _, _ in Self.makeRepo(isStarred: true) },
            updateContent: { repoID, content in await recorder.record(repoID: repoID, content: content) },
            lookupNote: { repoID in
                RepoNote(
                    repoId: repoID,
                    content: "saved note",
                    status: RepoStatus.using.rawValue,
                    isAIGenerated: false,
                    editedAt: "2026-07-01T10:00:00Z"
                )
            }
        )

        let note = try await writer.save(owner: "apple", repo: "swift", content: "saved note")
        let updated = await recorder.value

        #expect(updated?.repoID == 44_838_949)
        #expect(updated?.content == "saved note")
        #expect(note.editable == true)
        #expect(note.content == "saved note")
        #expect(note.editedAt == "2026-07-01T10:00:00Z")
    }

    @Test("missing repo is rejected")
    func missingRepoRejected() async {
        let writer = CompanionNoteWriter(
            lookupRepo: { _, _ in nil },
            updateContent: { _, _ in },
            lookupNote: { _ in nil }
        )

        await #expect(throws: CompanionNoteWriteError.repoNotFound) {
            _ = try await writer.save(owner: "apple", repo: "swift", content: "note")
        }
    }

    @Test("unstarred repo is rejected")
    func unstarredRepoRejected() async {
        let writer = CompanionNoteWriter(
            lookupRepo: { _, _ in Self.makeRepo(isStarred: false) },
            updateContent: { _, _ in },
            lookupNote: { _ in nil }
        )

        await #expect(throws: CompanionNoteWriteError.repoNotStarred) {
            _ = try await writer.save(owner: "apple", repo: "swift", content: "note")
        }
    }

    @Test("unstarred library repo can update note content")
    func unstarredLibraryRepoCanUpdateNote() async throws {
        let recorder = CompanionNoteUpdateRecorder()
        let writer = CompanionNoteWriter(
            lookupRepo: { _, _ in Self.makeRepo(isStarred: false) },
            lookupLibraryState: { _ in .inLibrary },
            updateContent: { repoID, content in await recorder.record(repoID: repoID, content: content) },
            lookupNote: { repoID in
                RepoNote(
                    repoId: repoID,
                    content: "library note",
                    status: RepoStatus.unread.rawValue,
                    libraryState: LibraryState.inLibrary.rawValue,
                    libraryUpdatedAt: "2026-07-01T10:00:00Z",
                    isAIGenerated: false,
                    editedAt: "2026-07-01T10:01:00Z"
                )
            }
        )

        let note = try await writer.save(owner: "apple", repo: "swift", content: "library note")
        let updated = await recorder.value

        #expect(updated?.repoID == 44_838_949)
        #expect(updated?.content == "library note")
        #expect(note.content == "library note")
    }

    @Test("content over 20000 characters is rejected before lookup")
    func oversizedContentRejected() async {
        let writer = CompanionNoteWriter(
            lookupRepo: { _, _ in
                Issue.record("repo lookup must not run after content size rejection")
                return nil
            },
            updateContent: { _, _ in },
            lookupNote: { _ in nil }
        )

        await #expect(throws: CompanionNoteWriteError.contentTooLarge) {
            _ = try await writer.save(
                owner: "apple",
                repo: "swift",
                content: String(repeating: "a", count: CompanionNoteWriter.maximumContentLength + 1)
            )
        }
    }

    private static func makeRepo(isStarred: Bool) -> Repo {
        Repo(
            id: 44_838_949,
            owner: "apple",
            name: "swift",
            fullName: "apple/swift",
            description: nil,
            language: "Swift",
            starsCount: 1,
            forksCount: 1,
            watchersCount: 1,
            topics: nil,
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/apple/swift",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: isStarred,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: nil
        )
    }
}

private actor CompanionNoteUpdateRecorder {
    private(set) var value: (repoID: Int64, content: String)?

    func record(repoID: Int64, content: String) {
        value = (repoID, content)
    }
}
