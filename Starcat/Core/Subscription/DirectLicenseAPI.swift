//
//  DirectLicenseAPI.swift
//  Starcat
//
//  Direct License 后端客户端。
//

import Foundation

/// Direct License API 客户端。
///
/// 该客户端只对接 Starcat 自己的 License API，不直接调用 Creem。Creem API Key、webhook
/// secret、订单结构都留在服务端，避免把支付网关细节或密钥带进 macOS 客户端。
struct DirectLicenseAPI: Sendable {
    var baseURL: URL
    var apiKey: String?
    var urlSession: URLSession
    var decoder: JSONDecoder
    var encoder: JSONEncoder

    init(
        baseURL: URL = DirectLicenseAPI.defaultBaseURL,
        apiKey: String? = DirectLicenseAPI.defaultAPIKey,
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.urlSession = urlSession
        self.decoder = JSONDecoder.starcatLicense
        self.encoder = JSONEncoder.starcatLicense
    }

    func checkout(_ request: DirectCheckoutRequest) async throws -> DirectPaymentURLResponse {
        try await send(path: AppEndpoints.DirectLicense.Paths.checkout, body: request)
    }

    func customerPortal(_ request: DirectCustomerPortalRequest) async throws -> DirectPaymentURLResponse {
        try await send(path: AppEndpoints.DirectLicense.Paths.customerPortal, body: request)
    }

    func cancelSubscription(_ request: DirectCancelSubscriptionRequest) async throws -> DirectSubscriptionSnapshot {
        try await send(path: AppEndpoints.DirectLicense.Paths.cancelSubscription, body: request)
    }

    func activate(_ request: DirectLicenseActivationRequest) async throws -> DirectLicenseSnapshot {
        try await send(path: AppEndpoints.DirectLicense.Paths.activate, body: request)
    }

    func validate(_ request: DirectLicenseValidationRequest) async throws -> DirectLicenseSnapshot {
        try await send(path: AppEndpoints.DirectLicense.Paths.validate, body: request)
    }

    func deactivate(_ request: DirectLicenseDeactivationRequest) async throws -> DirectLicenseSnapshot {
        try await send(path: AppEndpoints.DirectLicense.Paths.deactivate, body: request)
    }

    func devices(_ request: DirectLicenseDevicesRequest) async throws -> DirectLicenseSnapshot {
        try await send(path: AppEndpoints.DirectLicense.Paths.devices, body: request)
    }

    private func send<Request: Encodable, Response: Decodable>(
        path: String,
        body: Request
    ) async throws -> Response {
        let diagnostic = DiagnosticOperation(category: "license", name: "request",
            fields: ["route": .string(DiagnosticHTTPRequest.route(URL(string: path)))])
        return try await DiagnosticContext.$current.withValue(diagnostic) {
            do {
                let result: Response = try await performSend(path: path, body: body)
                diagnostic.finish()
                return result
            } catch {
                var fields: [String: DiagnosticValue] = [:]
                if let license = error as? DirectLicenseAPIError {
                    fields["preservesLocalEntitlement"] = .boolean(license.preservesLocalEntitlement)
                    fields["businessCode"] = .string(license.diagnosticCode)
                }
                diagnostic.finish(.failed, error: error, fields: fields)
                throw error
            }
        }
    }

    /// 诊断包装不改变鉴权、解码或错误映射，不添加激活与验证重试。
    private func performSend<Request: Encodable, Response: Decodable>(
        path: String, body: Request
    ) async throws -> Response {
        let url = AppEndpoints.appendPath(path, to: baseURL)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try encoder.encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await DiagnosticHTTP.data(for: request, using: urlSession, service: "license")
        } catch let error as URLError {
            throw DirectLicenseAPIError.transport(code: error.code.rawValue)
        } catch {
            throw DirectLicenseAPIError.transport(code: nil)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw mapHTTPError(response: response, data: data, path: path)
        }
        return try decoder.decode(Response.self, from: data)
    }

    private func mapHTTPError(response: URLResponse, data: Data, path: String) -> DirectLicenseAPIError {
        guard let http = response as? HTTPURLResponse else {
            return .invalidResponse
        }
        let body = (try? decoder.decode(DirectLicenseErrorResponse.self, from: data)) ?? DirectLicenseErrorResponse()
        let code = body.normalizedCode
        // 只记录编译期路径、固定错误码与 UUID trace；原始 message 可能包含授权码或上游密钥。
        let traceID = DirectLicenseAPIError.safeTraceID(body.traceID) ?? "-"
        let diagnosticCode = code ?? "http_\(http.statusCode)"
        DiagnosticLogStore.shared.enqueue(DiagnosticEvent(
            level: .warning, category: "license", operation: "businessResult",
            message: "License service rejected request", service: "license",
            statusCode: http.statusCode, errorCode: diagnosticCode,
            serverTraceID: DirectLicenseAPIError.safeTraceID(body.traceID),
            phase: "business", outcome: .failed,
            fields: ["route": .string(DiagnosticHTTPRequest.route(URL(string: path)))]
        ))
        AppLog.general.error(
            "[direct-license-api] path=\(path, privacy: .public) http_status=\(http.statusCode) code=\(diagnosticCode, privacy: .public) trace_id=\(traceID, privacy: .public)"
        )
        // 业务错误码优先于 HTTP status：后端可能用 403/409/502 承载同一 code，
        // 若先按 403→unauthorizedClient 会把「座位已满」误判成客户端鉴权失败。
        if code == "billing_not_ready" {
            return .billingNotReady
        }
        if code == "activation_limit_reached" {
            return .activationLimitReached
        }
        if code == "license_not_found" {
            return .licenseNotFound
        }
        if let code, ["license_revoked", "license_expired", "invalid_license"].contains(code) {
            return .licenseRejected(code: code)
        }
        switch http.statusCode {
        case 401, 403:
            return .unauthorizedClient
        case 404:
            // 路由 404 / 非 JSON 响应不能作为撤销本地 Pro 的证据，只认明确的业务 code。
            return .invalidResponse
        case 408, 429, 500...599:
            return .temporaryServerFailure(statusCode: http.statusCode, code: code)
        default:
            return .invalidResponse
        }
    }

    /// 当前构建选择的 License API 环境。
    ///
    /// 这里是配置选择，不是测试分支：Debug Direct build 可以长期指向 staging/Test Mode，
    /// Release Direct build 指向 live/Production。两套环境同时保存在 xcconfig/Info.plist 里，
    /// 避免每次测试完都删除或手改代码。
    private static var selectedEnvironment: String {
        let raw = Bundle.main.infoDictionary?["STARCAT_LICENSE_API_ENVIRONMENT"] as? String
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfEmpty ?? "live"
    }

    private static var defaultBaseURL: URL {
        switch selectedEnvironment {
        case "test", "staging":
            return infoPlistURL("STARCAT_LICENSE_API_TEST_BASE_URL") ?? AppEndpoints.DirectLicense.stagingURL
        default:
            return infoPlistURL("STARCAT_LICENSE_API_LIVE_BASE_URL") ?? AppEndpoints.DirectLicense.productionURL
        }
    }

    private static var defaultAPIKey: String? {
        switch selectedEnvironment {
        case "test", "staging":
            return infoPlistString("STARCAT_LICENSE_API_TEST_KEY")
        default:
            return infoPlistString("STARCAT_LICENSE_API_LIVE_KEY")
        }
    }

    private static func infoPlistURL(_ key: String) -> URL? {
        guard let raw = infoPlistString(key) else { return nil }
        return URL(string: raw)
    }

    private static func infoPlistString(_ key: String) -> String? {
        let raw = Bundle.main.infoDictionary?[key] as? String
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

enum DirectLicenseAPIError: Error, Equatable {
    case invalidResponse
    case transport(code: Int?)
    case temporaryServerFailure(statusCode: Int, code: String?)
    case unauthorizedClient
    case licenseNotFound
    case billingNotReady
    /// 授权码激活席位已满（Creem activation_limit）。后端约定 code=`ACTIVATION_LIMIT_REACHED`。
    /// 客户端只认自家 code；Creem 响应语义的识别留在服务端。
    case activationLimitReached
    case licenseRejected(code: String)

    /// 是否属于不能撤销本地 Pro 的临时失败。
    var preservesLocalEntitlement: Bool {
        switch self {
        case .transport, .temporaryServerFailure, .unauthorizedClient, .invalidResponse, .billingNotReady, .activationLimitReached:
            return true
        case .licenseNotFound, .licenseRejected:
            return false
        }
    }

    var diagnosticCode: String {
        switch self {
        case .invalidResponse:
            return "invalid_response"
        case let .transport(code):
            return code.map { "transport_\($0)" } ?? "transport_error"
        case let .temporaryServerFailure(statusCode, code):
            return Self.safeServerCode(code) ?? "http_\(statusCode)"
        case .unauthorizedClient:
            return "unauthorized_client"
        case .licenseNotFound:
            return "license_not_found"
        case .billingNotReady:
            return "billing_not_ready"
        case .activationLimitReached:
            return "activation_limit_reached"
        case let .licenseRejected(code):
            return Self.safeServerCode(code) ?? "license_rejected"
        }
    }

    /// 只让协议中明确的固定 code 进入日志与持久化验证记录，禁止从 message 推导诊断码。
    static func safeServerCode(_ raw: String?) -> String? {
        guard let code = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        switch code {
        case "billing_not_ready", "activation_limit_reached", "license_not_found",
             "license_revoked", "license_expired", "invalid_license", "provider_error",
             "provider_not_configured", "provider_unavailable", "license_provider_error",
             "payment_provider_error", "bad_request", "bad_json", "unauthorized_client",
             "rate_limit_exceeded":
            return code
        default:
            return nil
        }
    }

    /// 上游 trace 仅接受 UUID 并规范化，防止错误响应将用户内容或换行注入公开日志。
    static func safeTraceID(_ raw: String?) -> String? {
        UUID(uuidString: raw ?? "")?.uuidString.lowercased()
    }
}

extension DirectLicenseAPIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return String.l10n("settings.pro.direct.error.invalidResponse")
        case .transport:
            return String.l10n("settings.pro.direct.error.transport")
        case let .temporaryServerFailure(statusCode, _):
            return String(format: String.l10n("settings.pro.direct.error.temporaryServerFailure"), statusCode)
        case .unauthorizedClient:
            return String.l10n("settings.pro.direct.error.unauthorizedClient")
        case .licenseNotFound:
            return String.l10n("settings.pro.direct.error.licenseNotFound")
        case .billingNotReady:
            return String.l10n("settings.pro.direct.portal.syncing")
        case .activationLimitReached:
            return String.l10n("settings.pro.direct.error.activationLimitReached")
        case .licenseRejected:
            return String.l10n("settings.pro.direct.error.licenseRejected")
        }
    }
}

private struct DirectLicenseErrorResponse: Decodable {
    var code: String?
    var error: String?
    var traceID: String?

    var normalizedCode: String? {
        DirectLicenseAPIError.safeServerCode(code ?? error)
    }
}

private extension JSONDecoder {
    static var starcatLicense: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var starcatLicense: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
