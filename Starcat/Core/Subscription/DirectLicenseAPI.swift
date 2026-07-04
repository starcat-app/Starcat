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
    var urlSession: URLSession
    var decoder: JSONDecoder
    var encoder: JSONEncoder

    init(
        baseURL: URL = URL(string: "https://starcat-license-api.fly.dev")!,
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.decoder = JSONDecoder.starcatLicense
        self.encoder = JSONEncoder.starcatLicense
    }

    func activate(_ request: DirectLicenseActivationRequest) async throws -> DirectLicenseSnapshot {
        try await send(path: "/v1/direct/licenses/activate", body: request)
    }

    func validate(_ request: DirectLicenseValidationRequest) async throws -> DirectLicenseSnapshot {
        try await send(path: "/v1/direct/licenses/validate", body: request)
    }

    func deactivate(_ request: DirectLicenseDeactivationRequest) async throws -> DirectLicenseSnapshot {
        try await send(path: "/v1/direct/licenses/deactivate", body: request)
    }

    private func send<Request: Encodable>(
        path: String,
        body: Request
    ) async throws -> DirectLicenseSnapshot {
        var url = baseURL
        url.appendPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DirectLicenseAPIError.invalidResponse
        }
        return try decoder.decode(DirectLicenseSnapshot.self, from: data)
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
