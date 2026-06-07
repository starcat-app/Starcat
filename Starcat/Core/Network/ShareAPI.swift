//
//  ShareAPI.swift
//  Starcat
//
//  分享 API 客户端。
//

import Foundation

enum ShareAPIError: Error, LocalizedError {
    case invalidURL
    case transport(underlying: Error)
    case decodingError(underlying: Error)
    case serverError(message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "分享 API URL 无效"
        case .transport(let error):
            return "网络传输失败: \(error.localizedDescription)"
        case .decodingError(let error):
            return "解析响应失败: \(error.localizedDescription)"
        case .serverError(let message):
            return message ?? "服务端未知错误"
        }
    }
}

/// 分享 API 客户端。
actor ShareAPI {

    private static let timeout: TimeInterval = 30

    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        baseURL: URL = URL(string: "https://starcat-sharing-api.fly.dev/api")!,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = Self.timeout
            config.timeoutIntervalForResource = Self.timeout
            self.session = URLSession(configuration: config)
        }
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    func shareRepo(request: ShareRepoRequest) async throws -> ShareResponseDTO {
        let url = baseURL.appendingPathComponent("share")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Starcat/1.0", forHTTPHeaderField: "User-Agent")

        urlRequest.httpBody = try encoder.encode(request)

        do {
            let (data, response) = try await session.data(for: urlRequest)
            let validData = try validateResponse(data: data, response: response)
            return try decoder.decode(ShareResponseDTO.self, from: validData)
        } catch let error as ShareAPIError {
            throw error
        } catch {
            throw ShareAPIError.transport(underlying: error)
        }
    }

    private func validateResponse(data: Data, response: URLResponse) throws -> Data {
        guard let http = response as? HTTPURLResponse else {
            throw ShareAPIError.transport(underlying: URLError(.badServerResponse))
        }

        switch http.statusCode {
        case 200...299:
            return data
        case 400...499:
            let message = String(data: data, encoding: .utf8)
            throw ShareAPIError.serverError(message: message)
        case 500...599:
            throw ShareAPIError.serverError(message: "服务端内部错误 (\(http.statusCode))")
        default:
            throw ShareAPIError.transport(underlying: URLError(.badServerResponse))
        }
    }
}
