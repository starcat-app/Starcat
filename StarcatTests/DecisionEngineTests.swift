//
//  DecisionEngineTests.swift
//  StarcatTests
//
//  验证决策引擎抽象的选择与失败边界：只调用用户选中的实现；调用前不可用才回退
//  既有 LLM；调用已经开始后失败必须上抛，不能暗中改走另一引擎或双跑 LLM。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("DecisionEngine routing")
struct DecisionEngineTests {
    private enum StubError: Error {
        case failed
    }

    private final class RecordingEngine: DecisionEngineProviding {
        let id: DecisionEngineID
        var availability: DecisionEngineAvailability
        var shouldFail = false
        private(set) var callCount = 0

        init(id: DecisionEngineID, availability: DecisionEngineAvailability = .available) {
            self.id = id
            self.availability = availability
        }

        func evaluate(
            _ request: DecisionEvaluationRequest
        ) async throws -> DecisionEvaluationResponse {
            callCount += 1
            if shouldFail { throw StubError.failed }
            return DecisionEvaluationResponse(answers: request.questions.mapValues { _ in
                DecisionAnswer(type: "noul", noul: 0.9)
            })
        }
    }

    private final class RecordingListFallback: GitHubStarListSuggestionProviding {
        private(set) var callCount = 0

        func generateGitHubListSuggestions(
            for repos: [Repo],
            candidates: [GitHubStarListAIContext],
            existingListIDsByRepo: [Int64: Set<String>],
            existingListNamesByRepo: [Int64: [String]]
        ) async throws -> [Int64: [GitHubStarListAISuggestion]] {
            callCount += 1
            return [:]
        }
    }

    private func makeSettings() -> AppSettings {
        let name = "DecisionEngineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let settings = AppSettings(defaults: defaults, keychain: InMemoryKeychain())
        settings.decisionEngineEnabled = true
        settings.decisionEngineID = .laya
        settings.decisionGroupingSuggestionsEnabled = true
        settings.decisionTagSuggestionsEnabled = true
        return settings
    }

    private func makeService(
        settings: AppSettings,
        engines: [any DecisionEngineProviding]
    ) throws -> RepositoryDecisionService {
        let database = try InMemoryDatabaseManager()
        return RepositoryDecisionService(
            engineRegistry: DecisionEngineRegistry(engines: engines),
            settings: settings,
            readmeRepository: ReadmeRepository(database: database)
        )
    }

    private var repo: Repo {
        var repo = Repo.makeMinimal(owner: "acme", name: "starcat")
        repo.id = 1
        return repo
    }

    private var candidate: GitHubStarListAIContext {
        GitHubStarListAIContext(
            listId: "devtool",
            name: "DevTool",
            instruction: "developer tools",
            autoApplyEnabled: false
        )
    }

    @Test("只调用用户选择的 Laya，不触发 Jev 或 LLM")
    func routesOnlyToSelectedEngine() async throws {
        let settings = makeSettings()
        let jev = RecordingEngine(id: .jev)
        let laya = RecordingEngine(id: .laya)
        let fallback = RecordingListFallback()
        let service = try makeService(settings: settings, engines: [jev, laya])
        let router = DecisionGitHubListSuggestionRouter(
            llmProvider: fallback,
            decisionProvider: service,
            settings: settings
        )

        let result = try await router.generateGitHubListSuggestions(
            for: [repo],
            candidates: [candidate],
            existingListIDsByRepo: [:],
            existingListNamesByRepo: [:]
        )

        #expect(laya.callCount == 1)
        #expect(jev.callCount == 0)
        #expect(fallback.callCount == 0)
        #expect(result[1]?.first?.reason.hasPrefix("Laya P=") == true)
    }

    @Test("所选 Laya 调用前不可用时回退原 LLM")
    func unavailableSelectionFallsBackToLLM() async throws {
        let settings = makeSettings()
        let jev = RecordingEngine(id: .jev)
        let laya = RecordingEngine(
            id: .laya,
            availability: .unavailable(reason: "not installed")
        )
        let fallback = RecordingListFallback()
        let service = try makeService(settings: settings, engines: [jev, laya])
        let router = DecisionGitHubListSuggestionRouter(
            llmProvider: fallback,
            decisionProvider: service,
            settings: settings
        )

        _ = try await router.generateGitHubListSuggestions(
            for: [repo],
            candidates: [candidate],
            existingListIDsByRepo: [:],
            existingListNamesByRepo: [:]
        )

        #expect(laya.callCount == 0)
        #expect(jev.callCount == 0)
        #expect(fallback.callCount == 1)
    }

    @Test("所选 Laya 运行失败时上抛，不切 Jev 或 LLM")
    func runtimeFailureDoesNotFailOver() async throws {
        let settings = makeSettings()
        let jev = RecordingEngine(id: .jev)
        let laya = RecordingEngine(id: .laya)
        laya.shouldFail = true
        let fallback = RecordingListFallback()
        let service = try makeService(settings: settings, engines: [jev, laya])
        let router = DecisionGitHubListSuggestionRouter(
            llmProvider: fallback,
            decisionProvider: service,
            settings: settings
        )

        await #expect(throws: StubError.failed) {
            _ = try await router.generateGitHubListSuggestions(
                for: [repo],
                candidates: [candidate],
                existingListIDsByRepo: [:],
                existingListNamesByRepo: [:]
            )
        }
        #expect(laya.callCount == 1)
        #expect(jev.callCount == 0)
        #expect(fallback.callCount == 0)
    }

    @Test("Laya 标签建议保留引擎来源")
    func tagSuggestionKeepsLayaOrigin() async throws {
        let settings = makeSettings()
        let laya = RecordingEngine(id: .laya)
        let service = try makeService(settings: settings, engines: [laya])

        let result = try await service.generateBatchTagSuggestions(
            for: [repo],
            tagHintsByRepoID: [
                1: AITagHints(repoTags: [], libraryTags: ["Swift"])
            ]
        )

        #expect(result[1]?.first?.engine == .laya)
        #expect(result[1]?.first?.reason.hasPrefix("Laya P=") == true)
    }
}
