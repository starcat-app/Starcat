//
//  ExternalSearchCredentialTester.swift
//  Starcat
//
//  External Search Provider API Key 连通性测试器。
//
//  关键约束：
//  - 这是设置页的 credential test，不进入 SearchCenter 缓存、历史或用量计数；
//  - 测试 query 固定为 "who is dong4j"，maxResults 固定为 1，避免用户输入导致额外成本；
//  - 只有 2xx 且 provider response 可解码才算成功，成功后才保存候选 Key 并启用 Provider；
//  - 失败时不保存候选 Key，不记录 query/API Key 到错误详情。
//

import Foundation

struct ExternalSearchCredentialTestFailure: Equatable, Sendable {
    let friendlyMessage: String
    let technicalDetails: String?
}

enum ExternalSearchCredentialTestOutcome: Equatable, Sendable {
    case succeeded
    case saveFailed
    case failed(ExternalSearchCredentialTestFailure)
}

@MainActor
final class ExternalSearchCredentialTester {
    typealias ProviderFactory = @MainActor @Sendable (ExternalSearchProviderID, String) -> any ExternalSearchProvider

    nonisolated static let testQuery = "who is dong4j"
    nonisolated static let testMaxResults = 1

    private let settings: AppSettings
    private let providerFactory: ProviderFactory

    init(
        settings: AppSettings,
        providerFactory: @escaping ProviderFactory = ExternalSearchCredentialTester.defaultProviderFactory
    ) {
        self.settings = settings
        self.providerFactory = providerFactory
    }

    func test(provider providerID: ExternalSearchProviderID, candidateKey: String) async -> ExternalSearchCredentialTestOutcome {
        let trimmedKey = candidateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            return .failed(ExternalSearchCredentialTestFailure(
                friendlyMessage: ExternalSearchError.missingAPIKey(provider: providerID).friendlyMessage,
                technicalDetails: ExternalSearchError.missingAPIKey(provider: providerID).technicalDetails
            ))
        }

        do {
            let provider = providerFactory(providerID, trimmedKey)
            _ = try await provider.search(ExternalSearchRequest(
                query: Self.testQuery,
                purpose: .credentialTest,
                maxResults: Self.testMaxResults
            ))
            settings.setExternalSearchAPIKey(trimmedKey, for: providerID)
            settings.markExternalSearchCredentialVerified(for: providerID)
            var providerSettings = settings.externalSearchSettings(for: providerID)
            providerSettings.isEnabled = true
            settings.setExternalSearchSettings(providerSettings, for: providerID)
            guard settings.externalSearchAPIKey(for: providerID) == trimmedKey else {
                return .saveFailed
            }
            return .succeeded
        } catch {
            settings.clearExternalSearchCredentialVerification(for: providerID)
            if let external = error as? ExternalSearchError {
                return .failed(ExternalSearchCredentialTestFailure(
                    friendlyMessage: external.friendlyMessage,
                    technicalDetails: external.technicalDetails
                ))
            }
            return .failed(ExternalSearchCredentialTestFailure(
                friendlyMessage: error.localizedDescription,
                technicalDetails: nil
            ))
        }
    }

    private static func defaultProviderFactory(
        providerID: ExternalSearchProviderID,
        apiKey: String
    ) -> any ExternalSearchProvider {
        switch providerID {
        case .anySearch:
            return AnySearchExternalSearchProvider(apiKey: apiKey, anonymous: false, isEnabled: true)
        case .tavily:
            return TavilySearchProvider(apiKey: apiKey, isEnabled: true)
        case .exa:
            return ExaSearchProvider(apiKey: apiKey, isEnabled: true)
        case .braveLLMContext:
            return BraveLLMContextSearchProvider(apiKey: apiKey, isEnabled: true)
        }
    }
}

extension ExternalSearchError {
    var technicalDetails: String {
        let status = httpStatusCode.map { "\($0)" } ?? "n/a"
        let raw = rawMessage?.replacingOccurrences(of: ExternalSearchCredentialTester.testQuery, with: "[redacted-query]") ?? "n/a"
        return [
            "provider=\(providerID.rawValue)",
            "httpStatus=\(status)",
            "message=\(raw)"
        ].joined(separator: "\n")
    }

    private var httpStatusCode: Int? {
        switch self {
        case .invalidCredential(_, let statusCode, _),
             .paymentRequired(_, let statusCode, _),
             .serviceUnavailable(_, let statusCode, _):
            return statusCode
        case .rateLimited:
            return 429
        case .disabled, .missingAPIKey, .unverifiedCredential, .network, .invalidResponse:
            return nil
        }
    }

    private var rawMessage: String? {
        switch self {
        case .invalidCredential(_, _, let message),
             .paymentRequired(_, _, let message),
             .rateLimited(_, _, let message),
             .serviceUnavailable(_, _, let message):
            return message
        case .network(_, let message), .invalidResponse(_, let message):
            return message
        case .disabled, .missingAPIKey, .unverifiedCredential:
            return nil
        }
    }
}
