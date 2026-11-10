//
//  DiagnosticHTTP.swift
//  Starcat
//
//  记录已有请求的传输结果，不读取正文、鉴权或自定义主机，不增加重试。
//

import Foundation

/// 请求身份与业务操作身份分开；一次调用仅对应一次实际 URLSession 请求。
struct DiagnosticHTTPRequest: Sendable {
    let id = UUID().uuidString
    let operation: DiagnosticOperation
    let service: String

    init(service: String, method: String, route: String) {
        self.service = service
        self.operation = DiagnosticOperation(category: "network", name: service,
            fields: ["method": .string(method), "route": .string(route)])
    }

    /// 使用固定路径词表，账号、仓库、游标及自定义 endpoint 全部替换为占位。
    static func route(_ url: URL?) -> String {
        let vocabulary: Set<String> = [
            "api", "v1", "v2", "user", "users", "repos", "graphql", "starred", "followers",
            "following", "releases", "contents", "readme", "issues", "search", "license",
            "activate", "validate", "deactivate", "devices", "checkout", "portal", "cancel",
            "health", "trending", "weekly", "daily", "recommend", "events", "chat",
            "completions", "models", "messages", "responses"
        ]
        return (url?.path.split(separator: "/").prefix(8).map {
            vocabulary.contains(String($0).lowercased()) ? String($0).lowercased() : "id"
        } ?? []).joined(separator: ".")
    }

    /// HTTP 成功仅代表传输成功，解码或业务 envelope 必须由调用方再记录。
    func finish(response: URLResponse?, error: Error? = nil) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode
        let cancelled = error.map(DiagnosticFailure.isCancellation) ?? false
        let failed = error != nil || (status.map { $0 >= 400 } ?? true)
        let trace = ["x-request-id", "x-github-request-id", "x-trace-id", "trace-id"]
            .compactMap { http?.value(forHTTPHeaderField: $0) }
            .compactMap(DiagnosticEvent.safeTrace).first
        DiagnosticLogStore.shared.enqueue(DiagnosticEvent(
            level: failed && !cancelled ? .warning : .info,
            category: "network", operation: service, message: "HTTP attempt completed",
            service: service, statusCode: status,
            errorCode: error.map(DiagnosticFailure.code),
            underlying: error.map(DiagnosticEvent.summarize),
            operationID: operation.id, parentOperationID: operation.parentID,
            requestID: id, serverTraceID: trace, phase: "http",
            outcome: cancelled ? .cancelled : failed ? .failed : .succeeded,
            fields: ["receivedBytes": .integer(Int(response?.expectedContentLength ?? -1))]
        ))
        operation.finish(cancelled ? .cancelled : failed ? .failed : .succeeded, error: error)
    }
}

/// 复用原 URLSession 的配置、代理、缓存和测试 stub，保持所有业务语义。
enum DiagnosticHTTP {
    static func data(for request: URLRequest, using session: URLSession,
                     service: String) async throws -> (Data, URLResponse) {
        let attempt = DiagnosticHTTPRequest(service: service, method: request.httpMethod ?? "GET",
                                            route: DiagnosticHTTPRequest.route(request.url))
        do {
            let result = try await session.data(for: request)
            attempt.finish(response: result.1)
            return result
        } catch {
            attempt.finish(response: nil, error: error)
            throw error
        }
    }
}
