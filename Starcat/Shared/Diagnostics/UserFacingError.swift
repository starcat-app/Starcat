//
//  UserFacingError.swift
//  Starcat
//
//  面向用户的错误展示模型。
//
//  模块职责：
//  - 把底层 Error 归一化为「标题 / 说明 / 建议操作 / 诊断详情」；
//  - UI 只展示前三者，避免把 HTTP code、后端 envelope code、系统错误句子直接丢给用户；
//  - 诊断详情进入日志包，便于 dong4j 拿到用户反馈后快速定位。
//

import Foundation
import SwiftUI

/// 用户可读错误。
///
/// `message` 与 `recovery` 是本地化后的短文案；`diagnosticSummary` 可以包含状态码、
/// 底层错误描述等定位信息，不直接展示在主 UI。
struct UserFacingError: Equatable, Sendable {
    var title: String
    var message: String
    var recovery: String?
    var diagnosticSummary: String
    var statusCode: Int?
    var errorCode: String?

    static func map(
        _ error: Error,
        operation: String,
        service: String? = nil
    ) -> UserFacingError {
        if let network = error as? NetworkError {
            return mapNetwork(network, operation: operation, service: service)
        }
        if let envelope = error as? StarcatEnvelopeNetworkError {
            return mapEnvelope(envelope, operation: operation, service: service)
        }
        if let trending = error as? TrendingAPIError {
            return mapExternalService(error: trending, operation: operation, service: service ?? "trending")
        }
        if let weekly = error as? WeeklyAPIError {
            return mapExternalService(error: weekly, operation: operation, service: service ?? "weekly")
        }
        if let anySearch = error as? AnySearchError {
            return mapExternalService(error: anySearch, operation: operation, service: service ?? "anysearch")
        }
        if let ai = error as? AIClientError {
            return mapAI(ai, operation: operation, service: service)
        }
        if let database = error as? DatabaseError {
            return make(
                kind: .localData,
                operation: operation,
                service: service,
                diagnostic: database.localizedDescription
            )
        }
        if let keychain = error as? KeychainError {
            return make(
                kind: .secureStorage,
                operation: operation,
                service: service,
                diagnostic: keychain.localizedDescription
            )
        }
        if let urlError = error as? URLError {
            return mapURLError(urlError, operation: operation, service: service)
        }

        return make(
            kind: .unknown,
            operation: operation,
            service: service,
            diagnostic: error.localizedDescription
        )
    }

    func record(level: DiagnosticEvent.Level = .error, category: String, operation: String, service: String? = nil) {
        DiagnosticLogStore.record(
            level: level,
            category: category,
            operation: operation,
            message: message,
            service: service,
            statusCode: statusCode,
            errorCode: errorCode,
            underlying: diagnosticSummary
        )
    }

    private enum Kind {
        case networkUnavailable
        case unauthorized
        case rateLimited
        case notFound
        case serverUnavailable
        case decoding
        case localData
        case secureStorage
        case aiConfiguration
        case aiProvider
        case unknown
    }

    private static func mapNetwork(
        _ error: NetworkError,
        operation: String,
        service: String?
    ) -> UserFacingError {
        switch error {
        case .invalidURL, .invalidResponse:
            return make(kind: .serverUnavailable, operation: operation, service: service, diagnostic: error.localizedDescription)
        case .unauthorized:
            return make(kind: .unauthorized, operation: operation, service: service, diagnostic: error.localizedDescription, statusCode: 401)
        case .rateLimited(let retryAfter):
            return make(
                kind: .rateLimited,
                operation: operation,
                service: service,
                diagnostic: error.localizedDescription,
                statusCode: 403,
                context: "retryAfter=\(Int(retryAfter.rounded()))s"
            )
        case .notModified:
            return make(kind: .unknown, operation: operation, service: service, diagnostic: error.localizedDescription)
        case .notFound:
            return make(kind: .notFound, operation: operation, service: service, diagnostic: error.localizedDescription, statusCode: 404)
        case .serverError(let code):
            return make(kind: .serverUnavailable, operation: operation, service: service, diagnostic: error.localizedDescription, statusCode: code)
        case .clientError(let code, let message):
            return make(kind: code == 401 ? .unauthorized : .serverUnavailable, operation: operation, service: service, diagnostic: message ?? error.localizedDescription, statusCode: code)
        case .decodingError:
            return make(kind: .decoding, operation: operation, service: service, diagnostic: error.localizedDescription)
        case .transport(let underlying):
            if let urlError = underlying as? URLError {
                return mapURLError(urlError, operation: operation, service: service)
            }
            return make(kind: .networkUnavailable, operation: operation, service: service, diagnostic: error.localizedDescription)
        case .cancelled:
            return make(kind: .unknown, operation: operation, service: service, diagnostic: error.localizedDescription)
        }
    }

    private static func mapEnvelope(
        _ error: StarcatEnvelopeNetworkError,
        operation: String,
        service: String?
    ) -> UserFacingError {
        switch error {
        case .invalidURL:
            return make(kind: .serverUnavailable, operation: operation, service: service, diagnostic: error.localizedDescription)
        case .transport(let underlying):
            if let urlError = underlying as? URLError {
                return mapURLError(urlError, operation: operation, service: service)
            }
            return make(kind: .networkUnavailable, operation: operation, service: service, diagnostic: error.localizedDescription)
        case .decoding:
            return make(kind: .decoding, operation: operation, service: service, diagnostic: error.localizedDescription)
        case .serverError(let status, let code, let message):
            let kind: Kind = status == 401 ? .unauthorized : .serverUnavailable
            return make(
                kind: kind,
                operation: operation,
                service: service,
                diagnostic: message,
                statusCode: status,
                errorCode: code
            )
        }
    }

    private static func mapExternalService(
        error: LocalizedError,
        operation: String,
        service: String
    ) -> UserFacingError {
        make(
            kind: .serverUnavailable,
            operation: operation,
            service: service,
            diagnostic: error.errorDescription ?? String(describing: error)
        )
    }

    private static func mapAI(
        _ error: AIClientError,
        operation: String,
        service: String?
    ) -> UserFacingError {
        switch error {
        case .missingAPIKey, .invalidBaseURL:
            return make(kind: .aiConfiguration, operation: operation, service: service, diagnostic: error.localizedDescription)
        case .emptyResponse, .responseTruncated, .modelListRequestFailed:
            return make(kind: .aiProvider, operation: operation, service: service, diagnostic: error.localizedDescription)
        }
    }

    private static func mapURLError(
        _ error: URLError,
        operation: String,
        service: String?
    ) -> UserFacingError {
        let kind: Kind
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut:
            kind = .networkUnavailable
        case .userAuthenticationRequired, .userCancelledAuthentication:
            kind = .unauthorized
        default:
            kind = .networkUnavailable
        }
        return make(kind: kind, operation: operation, service: service, diagnostic: error.localizedDescription)
    }

    private static func make(
        kind: Kind,
        operation: String,
        service: String?,
        diagnostic: String,
        statusCode: Int? = nil,
        errorCode: String? = nil,
        context: String? = nil
    ) -> UserFacingError {
        let titleKey: String
        let messageKey: String
        let recoveryKey: String
        switch kind {
        case .networkUnavailable:
            titleKey = "error.user.network.title"
            messageKey = "error.user.network.message"
            recoveryKey = "error.user.network.recovery"
        case .unauthorized:
            titleKey = "error.user.unauthorized.title"
            messageKey = "error.user.unauthorized.message"
            recoveryKey = "error.user.unauthorized.recovery"
        case .rateLimited:
            titleKey = "error.user.rateLimited.title"
            messageKey = "error.user.rateLimited.message"
            recoveryKey = "error.user.rateLimited.recovery"
        case .notFound:
            titleKey = "error.user.notFound.title"
            messageKey = "error.user.notFound.message"
            recoveryKey = "error.user.notFound.recovery"
        case .serverUnavailable:
            titleKey = "error.user.service.title"
            messageKey = "error.user.service.message"
            recoveryKey = "error.user.service.recovery"
        case .decoding:
            titleKey = "error.user.decoding.title"
            messageKey = "error.user.decoding.message"
            recoveryKey = "error.user.decoding.recovery"
        case .localData:
            titleKey = "error.user.localData.title"
            messageKey = "error.user.localData.message"
            recoveryKey = "error.user.localData.recovery"
        case .secureStorage:
            titleKey = "error.user.secureStorage.title"
            messageKey = "error.user.secureStorage.message"
            recoveryKey = "error.user.secureStorage.recovery"
        case .aiConfiguration:
            titleKey = "error.user.aiConfiguration.title"
            messageKey = "error.user.aiConfiguration.message"
            recoveryKey = "error.user.aiConfiguration.recovery"
        case .aiProvider:
            titleKey = "error.user.aiProvider.title"
            messageKey = "error.user.aiProvider.message"
            recoveryKey = "error.user.aiProvider.recovery"
        case .unknown:
            titleKey = "error.user.unknown.title"
            messageKey = "error.user.unknown.message"
            recoveryKey = "error.user.unknown.recovery"
        }

        let serviceName = service ?? String.l10n("error.user.service.default")
        var diagnostic = DiagnosticEvent.redact(diagnostic)
        if let context {
            diagnostic += " (\(context))"
        }
        return UserFacingError(
            title: String.l10n(titleKey),
            message: String(format: String.l10n(messageKey), operation, serviceName),
            recovery: String.l10n(recoveryKey),
            diagnosticSummary: diagnostic,
            statusCode: statusCode,
            errorCode: errorCode
        )
    }
}

