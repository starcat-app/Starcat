//
//  CompanionLocalServerTests.swift
//  StarcatTests
//
//  验证 Chrome Companion 本机 HTTP 服务的最小安全外壳。
//

import Foundation
import Testing
@testable import Starcat

@Suite("CompanionLocalServer")
@MainActor
struct CompanionLocalServerTests {
    private func makeServer() throws -> CompanionLocalServer {
        let keychain = InMemoryKeychain()
        try keychain.storeCompanionToken("test-token")
        let defaults = try #require(UserDefaults(suiteName: "CompanionLocalServerTests.\(UUID().uuidString)"))
        return CompanionLocalServer(
            configuration: CompanionConfiguration(secureStore: keychain, defaults: defaults)
        )
    }

    private func makeServer(noteWriter: CompanionNoteWriter) throws -> CompanionLocalServer {
        let keychain = InMemoryKeychain()
        try keychain.storeCompanionToken("test-token")
        let defaults = try #require(UserDefaults(suiteName: "CompanionLocalServerTests.\(UUID().uuidString)"))
        return CompanionLocalServer(
            configuration: CompanionConfiguration(secureStore: keychain, defaults: defaults),
            noteWriter: noteWriter
        )
    }

    private func makeServer(actionHandler: CompanionActionHandler) throws -> CompanionLocalServer {
        let keychain = InMemoryKeychain()
        try keychain.storeCompanionToken("test-token")
        let defaults = try #require(UserDefaults(suiteName: "CompanionLocalServerTests.\(UUID().uuidString)"))
        return CompanionLocalServer(
            configuration: CompanionConfiguration(secureStore: keychain, defaults: defaults),
            actionHandler: actionHandler
        )
    }

    @Test("GET /local/v1/ping 带 token 返回 200")
    func pingReturnsOK() async throws {
        let server = try makeServer()
        let response = await server.handle(request("""
        GET /local/v1/ping HTTP/1.1\r
        Origin: chrome-extension://abc\r
        Authorization: Bearer test-token\r
        \r

        """))

        #expect(statusCode(response) == 200)
        #expect(bodyString(response).contains("\"status\":\"ok\""))
        #expect(header(response, "Access-Control-Allow-Origin") == "chrome-extension://abc")
    }

    @Test("缺 token 返回 401")
    func missingTokenReturnsUnauthorized() async throws {
        let server = try makeServer()
        let response = await server.handle(request("GET /local/v1/ping HTTP/1.1\r\n\r\n"))

        #expect(statusCode(response) == 401)
        #expect(bodyString(response).contains("unauthorized"))
    }

    @Test("非 extension origin 返回 403")
    func forbiddenOrigin() async throws {
        let server = try makeServer()
        let response = await server.handle(request("""
        GET /local/v1/ping HTTP/1.1\r
        Origin: https://github.com\r
        Authorization: Bearer test-token\r
        \r

        """))

        #expect(statusCode(response) == 403)
    }

    @Test("OPTIONS 预检通过 Origin 校验但不要求 token")
    func optionsDoesNotRequireToken() async throws {
        let server = try makeServer()
        let response = await server.handle(request("""
        OPTIONS /local/v1/ping HTTP/1.1\r
        Origin: chrome-extension://abc\r
        \r

        """))

        #expect(statusCode(response) == 204)
        #expect(header(response, "Access-Control-Allow-Private-Network") == "true")
    }

    @Test("未知路径返回 404")
    func unknownPathReturnsNotFound() async throws {
        let server = try makeServer()
        let response = await server.handle(request("""
        GET /local/v1/missing HTTP/1.1\r
        Authorization: Bearer test-token\r
        \r

        """))

        #expect(statusCode(response) == 404)
    }

    @Test("GET /local/v1/repo-context 返回 provider 上下文")
    func repoContextReturnsProviderPayload() async throws {
        let keychain = InMemoryKeychain()
        try keychain.storeCompanionToken("test-token")
        let defaults = try #require(UserDefaults(suiteName: "CompanionLocalServerTests.\(UUID().uuidString)"))
        let server = CompanionLocalServer(
            configuration: CompanionConfiguration(secureStore: keychain, defaults: defaults),
            contextProvider: CompanionContextProvider { owner, repo in
                #expect(owner == "apple")
                #expect(repo == "swift")
                return nil
            }
        )

        let response = await server.handle(request("""
        GET /local/v1/repo-context?owner=apple&repo=swift HTTP/1.1\r
        Origin: chrome-extension://abc\r
        Authorization: Bearer test-token\r
        \r

        """))

        #expect(statusCode(response) == 200)
        #expect(bodyString(response).contains("\"full_name\":\"apple\\/swift\""))
        #expect(bodyString(response).contains("\"known_to_starcat\":false"))
    }

    @Test("GET /local/v1/repo-context 缺 owner/repo 返回 400")
    func repoContextRequiresOwnerAndRepo() async throws {
        let server = try makeServer()
        let response = await server.handle(request("""
        GET /local/v1/repo-context?owner=apple HTTP/1.1\r
        Authorization: Bearer test-token\r
        \r

        """))

        #expect(statusCode(response) == 400)
        #expect(bodyString(response).contains("missing_repo"))
    }

    @Test("PATCH /local/v1/notes 保存私人笔记")
    func patchNotesSavesPrivateNote() async throws {
        let writer = CompanionNoteWriter(
            lookupRepo: { _, _ in Self.makeRepo(isStarred: true) },
            updateContent: { repoID, content in
                #expect(repoID == 44_838_949)
                #expect(content == "hello")
            },
            lookupNote: { repoID in
                RepoNote(
                    repoId: repoID,
                    content: "hello",
                    status: RepoStatus.using.rawValue,
                    isAIGenerated: false,
                    editedAt: "2026-07-01T10:00:00Z"
                )
            }
        )
        let server = try makeServer(noteWriter: writer)
        let response = await server.handle(request("""
        PATCH /local/v1/notes HTTP/1.1\r
        Authorization: Bearer test-token\r
        Content-Type: application/json\r
        \r
        {"owner":"apple","repo":"swift","content":"hello"}
        """))

        #expect(statusCode(response) == 200)
        #expect(bodyString(response).contains("\"status\":\"ok\""))
        #expect(bodyString(response).contains("\"content\":\"hello\""))
    }

    @Test("PATCH /local/v1/notes 未 star repo 返回 403")
    func patchNotesRejectsUnstarredRepo() async throws {
        let writer = CompanionNoteWriter(
            lookupRepo: { _, _ in Self.makeRepo(isStarred: false) },
            updateContent: { _, _ in },
            lookupNote: { _ in nil }
        )
        let server = try makeServer(noteWriter: writer)
        let response = await server.handle(request("""
        PATCH /local/v1/notes HTTP/1.1\r
        Authorization: Bearer test-token\r
        Content-Type: application/json\r
        \r
        {"owner":"apple","repo":"swift","content":"hello"}
        """))

        #expect(statusCode(response) == 403)
        #expect(bodyString(response).contains("repo_not_starred"))
    }

    @Test("POST /local/v1/actions/open 打开 codeflow")
    func postActionOpenCodeFlow() async throws {
        let recorder = CompanionActionRecorder()
        let handler = CompanionActionHandler(
            lookupRepo: { _, _ in Self.makeRepo(isStarred: true) },
            requestCodeFlow: { repo in
                recorder.record(.codeflow, repo: repo)
            }
        )
        let server = try makeServer(actionHandler: handler)
        let response = await server.handle(request("""
        POST /local/v1/actions/open HTTP/1.1\r
        Authorization: Bearer test-token\r
        Content-Type: application/json\r
        \r
        {"owner":"apple","repo":"swift","action":"codeflow"}
        """))

        #expect(statusCode(response) == 200)
        #expect(bodyString(response).contains("\"action\":\"codeflow\""))
        let event = recorder.value
        #expect(event?.action == .codeflow)
        #expect(event?.repo.fullName == "apple/swift")
    }

    @Test("POST /local/v1/actions/open 未 star repo 返回 403")
    func postActionRejectsUnstarredRepo() async throws {
        let handler = CompanionActionHandler(
            lookupRepo: { _, _ in Self.makeRepo(isStarred: false) }
        )
        let server = try makeServer(actionHandler: handler)
        let response = await server.handle(request("""
        POST /local/v1/actions/open HTTP/1.1\r
        Authorization: Bearer test-token\r
        Content-Type: application/json\r
        \r
        {"owner":"apple","repo":"swift","action":"codebase"}
        """))

        #expect(statusCode(response) == 403)
        #expect(bodyString(response).contains("repo_not_starred"))
    }

    private func request(_ raw: String) -> Data {
        Data(raw.utf8)
    }

    private func statusCode(_ data: Data) -> Int? {
        guard let firstLine = String(data: data, encoding: .utf8)?
            .components(separatedBy: "\r\n")
            .first else { return nil }
        return Int(firstLine.split(separator: " ").dropFirst().first ?? "")
    }

    private func header(_ data: Data, _ key: String) -> String? {
        guard let raw = String(data: data, encoding: .utf8),
              let headerEnd = raw.range(of: "\r\n\r\n") else { return nil }
        let target = key.lowercased()
        for line in raw[..<headerEnd.lowerBound].components(separatedBy: "\r\n").dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if name == target { return value }
        }
        return nil
    }

    private func bodyString(_ data: Data) -> String {
        guard let raw = String(data: data, encoding: .utf8),
              let headerEnd = raw.range(of: "\r\n\r\n") else { return "" }
        return String(raw[headerEnd.upperBound...])
    }

    nonisolated private static func makeRepo(isStarred: Bool) -> Repo {
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

@MainActor
private final class CompanionActionRecorder {
    private(set) var value: (action: CompanionActionDispatcher.Request.Kind, repo: Repo)?

    func record(_ action: CompanionActionDispatcher.Request.Kind, repo: Repo) {
        value = (action, repo)
    }
}
