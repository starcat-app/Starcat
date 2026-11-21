//
//  RepositoryDecisionService.swift
//  Starcat
//
//  仓库分组与标签复用的引擎无关决策服务。
//
//  本服务只负责领域 state、候选过滤、Noul 问题、结果校验与产品阈值；Jev 的
//  TypeSafe/OpenRouter 传输和 Laya 的 MLX 推理分别留在各自引擎实现中。一次调用
//  开始时固定所选引擎，运行中失败直接上抛，不自动切换实现或双跑 LLM。
//

import Foundation

enum DecisionEngineError: LocalizedError, Equatable, Sendable {
    case engineNotRegistered(DecisionEngineID)
    case engineUnavailable(DecisionEngineID, reason: String)
    case invalidAnswer(questionID: String)

    var errorDescription: String? {
        switch self {
        case .engineNotRegistered(let id):
            return "Decision engine is not registered: \(id.rawValue)"
        case let .engineUnavailable(id, reason):
            return "Decision engine is unavailable (\(id.rawValue)): \(reason)"
        case .invalidAnswer(let questionID):
            return "Decision engine returned an invalid Noul answer for \(questionID)"
        }
    }
}

@MainActor
final class RepositoryDecisionService {
    private static let groupingReadmeLimit = 2_400
    private static let tagsReadmeLimit = 4_000
    private static let tagProbabilityFloor = 0.50
    private static let tagVocabularyCap = 150

    private let engineRegistry: DecisionEngineRegistry
    private let settings: AppSettings
    private let readmeRepository: ReadmeRepository

    init(
        engineRegistry: DecisionEngineRegistry,
        settings: AppSettings,
        readmeRepository: ReadmeRepository
    ) {
        self.engineRegistry = engineRegistry
        self.settings = settings
        self.readmeRepository = readmeRepository
    }

    /// Jev 契约测试的窄装配入口；生产装配必须显式注册全部引擎。
    convenience init(
        client: TypeSafeClient,
        settings: AppSettings,
        readmeRepository: ReadmeRepository,
        keychain: any KeychainManaging = KeychainManager.shared
    ) {
        let jev = JevDecisionEngine(client: client, settings: settings, keychain: keychain)
        self.init(
            engineRegistry: DecisionEngineRegistry(engines: [jev]),
            settings: settings,
            readmeRepository: readmeRepository
        )
    }

    /// 路由器只在调用前用该快照决定是否回退既有 LLM。
    var isSelectedEngineAvailable: Bool {
        guard let engine = engineRegistry.engine(for: settings.decisionEngineID) else {
            return false
        }
        return engine.availability.isAvailable
    }

    // MARK: - GitHub Lists 分组建议

    func generateGitHubListSuggestions(
        for repos: [Repo],
        candidates: [GitHubStarListAIContext],
        existingListIDsByRepo: [Int64: Set<String>],
        existingListNamesByRepo: [Int64: [String]]
    ) async throws -> [Int64: [GitHubStarListAISuggestion]] {
        guard !repos.isEmpty else { return [:] }

        let eligibleCandidates = candidates.filter {
            !$0.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !eligibleCandidates.isEmpty else { return [:] }
        let engine = try selectedEngine()

        var results: [Int64: [GitHubStarListAISuggestion]] = [:]
        for repo in repos {
            try Task.checkCancellation()

            let existingListIDs = existingListIDsByRepo[repo.id] ?? []
            let askableCandidates = eligibleCandidates.filter { !existingListIDs.contains($0.listId) }
            guard !askableCandidates.isEmpty else {
                results[repo.id] = []
                continue
            }

            let readme = (try? await readmeRepository.findContent(repoId: repo.id)) ?? ""
            let state = RepositoryDecisionState(
                repo: repo,
                readmeExcerpt: String(readme.prefix(Self.groupingReadmeLimit)),
                existingListNames: existingListNamesByRepo[repo.id] ?? [],
                existingTags: []
            )
            var questions: [String: DecisionQuestion] = [:]
            questions.reserveCapacity(askableCandidates.count)
            for candidate in askableCandidates {
                questions["list::\(candidate.listId)"] = Self.listMembershipQuestion(for: candidate)
            }

            let response = try await engine.evaluate(DecisionEvaluationRequest(
                state: .repository(state),
                questions: questions,
                operation: .githubListGrouping
            ))
            var suggestions: [GitHubStarListAISuggestion] = []
            suggestions.reserveCapacity(askableCandidates.count)
            for candidate in askableCandidates {
                let questionID = "list::\(candidate.listId)"
                let probability = try Self.validatedNoulProbability(
                    in: response,
                    questionID: questionID
                )
                suggestions.append(GitHubStarListAISuggestion(
                    listId: candidate.listId,
                    confidence: min(max(probability, 0), 1),
                    reason: "\(engine.id.displayName) P=\(String(format: "%.2f", probability))"
                ))
            }

            suggestions.sort {
                if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
                return $0.listId < $1.listId
            }
            results[repo.id] = try GitHubStarListAISuggestionPolicy.validatedModelSuggestions(
                suggestions,
                candidates: eligibleCandidates,
                existingListIDs: existingListIDs
            )
        }
        return results
    }

    private static func listMembershipQuestion(
        for candidate: GitHubStarListAIContext
    ) -> DecisionQuestion {
        .noul(
            instructions: .object([
                "main_question": "Should the repository described by `repository` and `readmeExcerpt` be added to this GitHub list?",
                "list_name": candidate.name,
                "list_rule": candidate.instruction,
                "existing_memberships_note": "`existingListNames` contains GitHub lists the repository already belongs to.",
            ]),
            criteria: DecisionNoulCriteria(
                true: "The repository clearly satisfies `list_rule`.",
                false: "The repository does not satisfy `list_rule`."
            )
        )
    }

    // MARK: - 批量标签建议

    func generateBatchTagSuggestions(
        for repos: [Repo],
        tagHintsByRepoID: [Int64: AITagHints]
    ) async throws -> [Int64: [AITagSuggestion]] {
        guard !repos.isEmpty else { return [:] }
        let engine = try selectedEngine()
        let maximumTagCount = settings.clampedAITagSuggestionCounts.maximum

        var orderedVocabulary: [String] = []
        var seenKeys: Set<String> = []
        for repo in repos {
            for name in tagHintsByRepoID[repo.id]?.libraryTags ?? [] {
                let key = AITagSuggestionPolicy.canonicalKey(name)
                guard !key.isEmpty, seenKeys.insert(key).inserted else { continue }
                orderedVocabulary.append(name)
                if orderedVocabulary.count >= Self.tagVocabularyCap { break }
            }
            if orderedVocabulary.count >= Self.tagVocabularyCap { break }
        }
        guard !orderedVocabulary.isEmpty else {
            return Dictionary(uniqueKeysWithValues: repos.map { ($0.id, []) })
        }

        var results: [Int64: [AITagSuggestion]] = [:]
        for repo in repos {
            try Task.checkCancellation()

            let hints = tagHintsByRepoID[repo.id] ?? .empty
            let repoTagKeys = Set(hints.repoTags.map(AITagSuggestionPolicy.canonicalKey))
            let candidates = orderedVocabulary.filter {
                !repoTagKeys.contains(AITagSuggestionPolicy.canonicalKey($0))
            }
            guard !candidates.isEmpty else {
                results[repo.id] = []
                continue
            }

            let readme = (try? await readmeRepository.findContent(repoId: repo.id)) ?? ""
            let state = RepositoryDecisionState(
                repo: repo,
                readmeExcerpt: String(readme.prefix(Self.tagsReadmeLimit)),
                existingListNames: [],
                existingTags: hints.repoTags
            )
            var questions: [String: DecisionQuestion] = [:]
            questions.reserveCapacity(candidates.count)
            for name in candidates {
                questions["tag::\(name)"] = Self.tagMembershipQuestion(for: name)
            }

            let response = try await engine.evaluate(DecisionEvaluationRequest(
                state: .repository(state),
                questions: questions,
                operation: .tagReuse
            ))
            var suggestions: [AITagSuggestion] = []
            for name in candidates {
                let questionID = "tag::\(name)"
                let probability = try Self.validatedNoulProbability(
                    in: response,
                    questionID: questionID
                )
                guard probability >= Self.tagProbabilityFloor else { continue }
                suggestions.append(AITagSuggestion(
                    name: name,
                    confidence: min(max(probability, 0), 1),
                    reason: "\(engine.id.displayName) P=\(String(format: "%.2f", probability))",
                    engine: engine.id.tagSuggestionEngine
                ))
            }

            results[repo.id] = AITagSuggestionPolicy.normalizedSuggestions(
                suggestions,
                vocabulary: hints.repoTags + orderedVocabulary,
                maximumSuggestionCount: maximumTagCount
            )
        }
        return results
    }

    private static func tagMembershipQuestion(for tagName: String) -> DecisionQuestion {
        .noul(
            instructions: .text("""
            Should the existing user tag "\(tagName)" be applied to the repository described by `repository` and `readmeExcerpt`? \
            `existingTags` lists tags the repository already has; do not re-suggest synonyms of them.
            """),
            criteria: DecisionNoulCriteria(
                true: "The tag accurately describes an important aspect of this repository.",
                false: "The tag is only loosely related, or the repository already has a tag with the same meaning."
            )
        )
    }

    private func selectedEngine() throws -> any DecisionEngineProviding {
        let selectedID = settings.decisionEngineID
        guard let engine = engineRegistry.engine(for: selectedID) else {
            throw DecisionEngineError.engineNotRegistered(selectedID)
        }
        switch engine.availability {
        case .available:
            return engine
        case .unavailable(let reason):
            throw DecisionEngineError.engineUnavailable(selectedID, reason: reason)
        }
    }

    private static func validatedNoulProbability(
        in response: DecisionEvaluationResponse,
        questionID: String
    ) throws -> Double {
        guard let probability = response.answers[questionID]?.noul,
              probability.isFinite,
              (0...1).contains(probability)
        else {
            throw DecisionEngineError.invalidAnswer(questionID: questionID)
        }
        return probability
    }
}

extension RepositoryDecisionService: GitHubStarListSuggestionProviding {}
