//
//  CompanionModelsTests.swift
//  StarcatTests
//
//  验证 Chrome Companion 本机 API DTO 的 JSON 契约。
//

import Foundation
import Testing
@testable import Starcat

@Suite("CompanionModels")
struct CompanionModelsTests {

    @Test("ping response uses numeric schema version and array capabilities")
    func pingEncodingShape() throws {
        let data = try CompanionJSONTestEncoder.encode(CompanionPingResponse.ok)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["schema_version"] as? Int == 1)
        #expect(object["status"] as? String == "ok")
        #expect(object["app"] as? String == "Starcat")
        #expect(object["capabilities"] as? [String] == ["repo-context", "notes", "actions", "events"])
    }

    @Test("repo-context response keeps snake_case contract")
    func repoContextEncodingShape() throws {
        let response = CompanionRepoContextResponse(
            schemaVersion: 1,
            repo: CompanionRepoDTO(
                owner: "apple",
                name: "swift",
                fullName: "apple/swift",
                repoID: 44_838_949,
                htmlURL: "https://github.com/apple/swift",
                knownToStarcat: true,
                isStarred: true
            ),
            recommendations: [],
            wikiLinks: [
                CompanionWikiLinkDTO(source: "deepwiki", title: "DeepWiki", url: "https://deepwiki.com/apple/swift")
            ],
            note: CompanionNoteDTO(editable: true, content: "note", editedAt: "2026-07-01T10:00:00Z"),
            health: CompanionHealthDTO(score: 82, grade: "B", computedAt: "2026-07-01T10:00:00Z"),
            openssf: CompanionOpenSSFDTO(score: 7.4, scoreDate: "2026-06-30"),
            actions: CompanionActionsDTO(openInStarcat: true, codeflow: true, codebase: true),
            entitlement: CompanionEntitlementDTO(isPro: true)
        )

        let data = try CompanionJSONTestEncoder.encode(response)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let repo = try #require(object["repo"] as? [String: Any])
        let actions = try #require(object["actions"] as? [String: Any])
        let entitlement = try #require(object["entitlement"] as? [String: Any])

        #expect(repo["full_name"] as? String == "apple/swift")
        #expect(repo["repo_id"] as? Int == 44_838_949)
        #expect(repo["html_url"] as? String == "https://github.com/apple/swift")
        #expect(repo["known_to_starcat"] as? Bool == true)
        #expect(repo["is_starred"] as? Bool == true)
        #expect(object["wiki_links"] is [[String: Any]])
        #expect(actions["open_in_starcat"] as? Bool == true)
        #expect(entitlement["is_pro"] as? Bool == true)
    }

    @Test("event envelope keeps snake_case contract")
    func eventEnvelopeEncodingShape() throws {
        let event = CompanionEventEnvelope(
            schemaVersion: 1,
            type: "note.updated",
            repoID: 44_838_949,
            note: CompanionNoteDTO(editable: true, content: "live note", editedAt: "2026-07-01T10:00:00Z")
        )

        let data = try CompanionJSONTestEncoder.encode(event)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let note = try #require(object["note"] as? [String: Any])

        #expect(object["schema_version"] as? Int == 1)
        #expect(object["type"] as? String == "note.updated")
        #expect(object["repo_id"] as? Int == 44_838_949)
        #expect(note["content"] as? String == "live note")
        #expect(note["edited_at"] as? String == "2026-07-01T10:00:00Z")
    }
}

private enum CompanionJSONTestEncoder {
    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(value)
    }
}
