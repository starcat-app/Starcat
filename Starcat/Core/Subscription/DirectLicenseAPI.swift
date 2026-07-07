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

    func activate(_ request: DirectLicenseActivationRequest) async throws -> DirectLicenseSnapshot {
        try await send(path: AppEndpoints.DirectLicense.Paths.activate, body: request)
    }

    func validate(_ request: DirectLicenseValidationRequest) async throws -> DirectLicenseSnapshot {
        try await send(path: AppEndpoints.DirectLicense.Paths.validate, body: request)
    }

    func deactivate(_ request: DirectLicenseDeactivationRequest) async throws -> DirectLicenseSnapshot {
        try await send(path: AppEndpoints.DirectLicense.Paths.deactivate, body: request)
    }

    private func send<Request: Encodable, Response: Decodable>(
        path: String,
        body: Request
    ) async throws -> Response {
        let url = AppEndpoints.appendPath(path, to: baseURL)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DirectLicenseAPIError.invalidResponse
        }
        return try decoder.decode(Response.self, from: data)
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
