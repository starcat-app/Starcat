//
//  JevDecisionEngine.swift
//  Starcat
//
//  Jev 决策引擎实现。
//
//  OpenRouter 是 Jev 的第二条承载路径，不是独立决策引擎：原生 TypeSafe Key
//  始终优先；原生 Key 缺失或最近一次显式连接测试失败时，才使用第一个已启用、
//  已验证且有 Key 的 OpenRouter profile。普通业务请求失败不会自动切换路径。
//

import Foundation

/// 一次 Jev 请求最终选中的凭据与承载 API。
///
/// API Key 只在内存中逐次传给 client，不写入 AppSettings 或日志。
struct JevDecisionAccess: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case typeSafe
        case openRouter(profileID: String, displayName: String)
    }

    let source: Source
    let apiKey: String
    let modelID: String

    var api: TypeSafeDecisionAPI {
        switch source {
        case .typeSafe:
            return .typeSafe
        case .openRouter:
            return .openRouter
        }
    }

    var openRouterProfileDisplayName: String? {
        guard case let .openRouter(_, displayName) = source else { return nil }
        return displayName
    }
}

/// 远端 Jev 实现。只负责凭据/承载路径与协议映射，不包含仓库候选筛选逻辑。
@MainActor
final class JevDecisionEngine: DecisionEngineProviding {
    static let keychainServiceID = "typesafe-ai"
    /// 固定版本避免 `jev-latest` 漂移后破坏已调好的概率阈值。
    static let defaultModelID = "jev-1.13.0"
    /// OpenRouter Decisions 使用独立模型命名空间，同样固定版本。
    static let openRouterModelID = "typesafe/jev-1.13"

    let id: DecisionEngineID = .jev

    private let client: TypeSafeClient
    private let settings: AppSettings
    private let keychain: any KeychainManaging

    init(
        client: TypeSafeClient,
        settings: AppSettings,
        keychain: any KeychainManaging = KeychainManager.shared
    ) {
        self.client = client
        self.settings = settings
        self.keychain = keychain
    }

    var availability: DecisionEngineAvailability {
        Self.resolveAccess(settings: settings, keychain: keychain) == nil
            ? .unavailable(reason: "Jev decision API key is not configured")
            : .available
    }

    func evaluate(_ request: DecisionEvaluationRequest) async throws -> DecisionEvaluationResponse {
        guard let access = Self.resolveAccess(settings: settings, keychain: keychain) else {
            throw TypeSafeClientError.missingAPIKey
        }

        let questions = request.questions.mapValues { question in
            TypeSafeQuestion.noul(
                instructions: question.instructions.typeSafeValue,
                criteria: question.criteria.map {
                    TypeSafeNoulCriteria(true: $0.true, false: $0.false)
                }
            )
        }
        let response = try await client.evaluate(
            state: request.state,
            model: access.modelID,
            questions: questions,
            apiKey: access.apiKey,
            api: access.api,
            operation: request.operation.typeSafeValue
        )

        var answers: [String: DecisionNoulAnswer] = [:]
        answers.reserveCapacity(request.questions.count)
        for questionID in request.questions.keys {
            guard let answer = response.answers[questionID],
                  answer.type == "noul",
                  let probability = answer.noul,
                  probability.isFinite,
                  (0...1).contains(probability)
            else {
                throw TypeSafeClientError.invalidAnswer(questionID: questionID)
            }
            answers[questionID] = DecisionNoulAnswer(probability: probability)
        }
        return DecisionEvaluationResponse(answers: answers)
    }

    // MARK: - 凭据 / 模型解析

    /// 顺序固定为「可用的原生 TypeSafe → OpenRouter fallback」。
    ///
    /// `nativeAPIKeyOverride` 只供设置页测试尚未落盘的草稿；显式传入时允许重测
    /// 失败状态中的原生 Key，空字符串则跳过已存 Key 并检查 fallback。
    static func resolveAccess(
        settings: AppSettings,
        keychain: any KeychainManaging,
        nativeAPIKeyOverride: String? = nil
    ) -> JevDecisionAccess? {
        let rawNativeKey: String?
        if let nativeAPIKeyOverride {
            rawNativeKey = nativeAPIKeyOverride
        } else {
            rawNativeKey = try? keychain.loadServiceAPIKey(forService: keychainServiceID)
        }

        let mayUseNativeKey = nativeAPIKeyOverride != nil || !settings.typesafeNativeKeyTestFailed
        if mayUseNativeKey, let nativeKey = normalizedKey(rawNativeKey) {
            return JevDecisionAccess(
                source: .typeSafe,
                apiKey: nativeKey,
                modelID: resolvedNativeModelID(settings: settings)
            )
        }
        return resolveOpenRouterFallback(settings: settings, keychain: keychain)
    }

    /// 只接受已启用且连接测试成功的 OpenRouter profile，并按设置中的稳定顺序取第一项。
    /// profile 的自定义 Base URL 不参与 Decisions 请求，防止把 Key 发往非官方主机。
    static func resolveOpenRouterFallback(
        settings: AppSettings,
        keychain: any KeychainManaging
    ) -> JevDecisionAccess? {
        for profile in settings.aiProviderProfiles
        where profile.provider == .openRouter && profile.isVerifiedConfiguration {
            let rawKey = try? keychain.loadAIKey(forProvider: profile.id)
            guard let apiKey = normalizedKey(rawKey) else { continue }
            let displayName = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return JevDecisionAccess(
                source: .openRouter(
                    profileID: profile.id,
                    displayName: displayName.isEmpty ? "OpenRouter" : displayName
                ),
                apiKey: apiKey,
                modelID: openRouterModelID
            )
        }
        return nil
    }

    private static func normalizedKey(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func resolvedNativeModelID(settings: AppSettings) -> String {
        let trimmed = settings.typesafeModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultModelID : trimmed
    }
}

private extension DecisionQuestionInstructions {
    var typeSafeValue: TypeSafeQuestionInstructions {
        switch self {
        case .text(let value):
            return .text(value)
        case .object(let value):
            return .object(value)
        }
    }
}

private extension DecisionEvaluationOperation {
    var typeSafeValue: TypeSafeEvaluationOperation {
        switch self {
        case .unspecified:
            return .unspecified
        case .githubListGrouping:
            return .githubListGrouping
        case .tagReuse:
            return .tagReuse
        case .connectionTest:
            return .connectionTest
        case .searchIntent:
            return .searchIntent
        }
    }
}
