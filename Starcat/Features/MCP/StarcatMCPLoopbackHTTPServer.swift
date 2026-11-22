//
//  StarcatMCPLoopbackHTTPServer.swift
//  Starcat
//
//  Starcat MCP Runtime 的 HTTP 适配器。
//
//  MCP Swift SDK 的 server transport 是 framework-agnostic：它负责把 HTTPRequest 转成
//  JSON-RPC，但不负责监听端口。Starcat 是 macOS 原生 App，不需要为了一个 loopback
//  端口引入 NIO/Vapor，因此这里用 Network.framework 写一层极薄 adapter。
//
//  关键约束：
//  - 默认只监听 `127.0.0.1`；允许其他设备连接时扩大监听范围，两个模式都使用 HTTP；
//  - P0 使用 stateless HTTP，一次连接处理一个请求，不支持 SSE/server push；
//  - MCP 请求体上限 8 MiB，System One 图片请求体上限 32 MiB。
//

import Foundation
import MCP
import Network

@MainActor
final class StarcatMCPLoopbackHTTPServer {
    private let port: Int
    private let runtime: any StarcatMCPHTTPRuntime
    private let allowsRemoteConnections: Bool
    private let requestValidator: @MainActor (StarcatHTTPServerRequest) -> StarcatHTTPServerError?
    private let routeHandler: @MainActor (StarcatHTTPServerRequest) async -> StarcatHTTPServerRouteResponse?
    private let publicRouteHandler: @MainActor (StarcatHTTPServerRequest) async -> StarcatHTTPServerRouteResponse?
    private let queue = DispatchQueue(label: "com.starcat.mcp.http")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var startupContinuation: CheckedContinuation<Int, Error>?

    init(
        port: Int,
        runtime: any StarcatMCPHTTPRuntime,
        allowsRemoteConnections: Bool = false,
        requestValidator: @escaping @MainActor (StarcatHTTPServerRequest) -> StarcatHTTPServerError?,
        routeHandler: @escaping @MainActor (StarcatHTTPServerRequest) async -> StarcatHTTPServerRouteResponse? = { _ in nil },
        publicRouteHandler: @escaping @MainActor (StarcatHTTPServerRequest) async -> StarcatHTTPServerRouteResponse? = { _ in nil }
    ) {
        self.port = port
        self.runtime = runtime
        self.allowsRemoteConnections = allowsRemoteConnections
        self.requestValidator = requestValidator
        self.routeHandler = routeHandler
        self.publicRouteHandler = publicRouteHandler
    }

    func start() throws {
        guard listener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw StarcatMCPError.invalidArguments("Invalid MCP port: \(port)")
        }
        // R-06.4 2026-06-21 dong4j MCP 30s timeout 根因：
        // 在 macOS 26 (Darwin 25) 上，NWParameters.tcp 默认会让 NWListener
        // 进入 IPv6 dual-stack，最终 listen 在 `*:5551`（IPv6 wildcard）；
        // Claude / curl 走 IPv4 127.0.0.1 发起连接，macOS 不做 IPv4-mapped IPv6
        // 转发，结果 TCP 握手成功但 server 不 accept，客户端 30s 超时。
        // 修复：显式要求 IPv4 loopback + 端口放 requiredLocalEndpoint，on: .any
        // 规避 commit 579bc46 提到的「requiredLocalEndpoint 与 on: 同时指定同端口
        // 触发 EINVAL」。
        let parameters = NWParameters.tcp
        let listener: NWListener
        if allowsRemoteConnections {
            listener = try NWListener(using: parameters, on: nwPort)
        } else {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address.loopback), port: nwPort)
            listener = try NWListener(using: parameters, on: .any)
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.accept(connection)
            }
        }
        let diagnosticPort = port
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleListenerState(state, diagnosticPort: diagnosticPort)
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// 在公布地址或启动 Harness 之前等待 socket bind，避免客户端首次请求撞上启动过程。
    func startAndWaitUntilReady() async throws -> Int {
        if let listener, let boundPort = listener.port?.rawValue, boundPort != 0 {
            return Int(boundPort)
        }
        return try await withCheckedThrowingContinuation { continuation in
            startupContinuation = continuation
            do {
                try start()
            } catch {
                startupContinuation = nil
                continuation.resume(throwing: error)
            }
        }
    }

    func stop() {
        if let startupContinuation {
            self.startupContinuation = nil
            startupContinuation.resume(throwing: CancellationError())
        }
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
    }

    private func handleListenerState(_ state: NWListener.State, diagnosticPort: Int) {
        switch state {
        case .ready:
            guard let startupContinuation else { return }
            self.startupContinuation = nil
            guard let boundPort = listener?.port?.rawValue, boundPort != 0 else {
                startupContinuation.resume(throwing: StarcatMCPError.invalidArguments(
                    "MCP listener became ready without a bound port."
                ))
                return
            }
            startupContinuation.resume(returning: Int(boundPort))
        case .failed(let error):
            AppLog.network.error("MCP HTTP listener failed: \(error.localizedDescription, privacy: .public)")
            if let startupContinuation {
                self.startupContinuation = nil
                startupContinuation.resume(throwing: error)
                // 启动失败交由 MCPService 记录，避免同一失败跨层重复提醒。
                return
            }
            if case .posix(.EADDRINUSE) = error { return }
            DiagnosticLogStore.record(
                level: .error,
                visibility: .issue,
                category: "mcp",
                operation: "mcp.listenerRuntime",
                message: "MCP HTTP listener failed after startup",
                summary: .serviceUnavailable,
                impact: .blocked,
                underlying: DiagnosticEvent.summarize(error),
                context: ["port": String(diagnosticPort)], error: error
            )
        case .cancelled:
            if let startupContinuation {
                self.startupContinuation = nil
                startupContinuation.resume(throwing: CancellationError())
            }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard case .cancelled = state, let connection else { return }
            Task { @MainActor in
                self?.connections.removeValue(forKey: ObjectIdentifier(connection))
            }
        }
        connection.start(queue: queue)
        Task {
            await handle(connection)
        }
    }

    private func handle(_ connection: NWConnection) async {
        let diagnostic = DiagnosticOperation(category: "mcp", name: "request")
        var outcome: DiagnosticEvent.Outcome = .failed
        defer { diagnostic.finish(Task.isCancelled ? .cancelled : outcome) }
        do {
            let request = try await readRequest(from: connection)
            // `/pairing/exchange` 在认证前处理：它只接受五分钟有效的一次性 secret，
            // 成功后仍需用户在 App 内确认。其它路径继续走原有 Bearer 校验。
            if request.path == "/pairing/exchange", let routed = await routeHandler(request) {
                outcome = routed.statusCode < 400 ? .succeeded : .failed
                send(routed.httpData, on: connection)
                return
            }
            if let error = requestValidator(request) {
                send(error.httpData, on: connection)
                return
            }
            if let routed = await publicRouteHandler(request) {
                outcome = routed.statusCode < 400 ? .succeeded : .failed
                send(routed.httpData, on: connection)
                return
            }

            let httpRequest = HTTPRequest(
                method: request.method,
                headers: request.headers,
                body: request.body,
                path: request.path
            )
            let response = await runtime.handle(httpRequest)
            outcome = response.statusCode < 400 ? .succeeded : .failed
            diagnostic.event(phase: "responded", fields: ["status": .integer(response.statusCode)])
            let routed = StarcatHTTPServerRouteResponse(
                statusCode: response.statusCode,
                body: response.bodyData ?? Data(),
                headers: response.headers
            )
            send(routed.httpData, on: connection)
        } catch let error as StarcatHTTPServerError {
            send(error.httpData, on: connection)
        } catch {
            send(StarcatHTTPServerError.badRequest(error.localizedDescription).httpData, on: connection)
        }
    }

    private func readRequest(from connection: NWConnection) async throws -> StarcatHTTPServerRequest {
        var buffer = Data()
        while true {
            let chunk = try await receiveChunk(from: connection)
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)
            if let request = try StarcatHTTPServerRequest(data: buffer) {
                return request
            }
        }
        throw StarcatHTTPServerError.badRequest("Incomplete HTTP request.")
    }

    private func receiveChunk(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func send(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

}

/// 共用 listener 响应编码，保证认证拒绝与业务响应使用相同的 HTTP 首部结束符。
struct StarcatHTTPServerRouteResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    init(statusCode: Int, body: Data, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
    }

    var httpData: Data {
        var headers = self.headers
        headers["Content-Length"] = "\(body.count)"
        headers["Content-Type"] = headers["Content-Type"] ?? "application/json"
        headers["Connection"] = "close"

        let reason: String
        switch statusCode {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 409: reason = "Conflict"
        case 413: reason = "Payload Too Large"
        case 415: reason = "Unsupported Media Type"
        case 421: reason = "Misdirected Request"
        case 502: reason = "Bad Gateway"
        case 503: reason = "Service Unavailable"
        default: reason = "Error"
        }
        var head = "HTTP/1.1 \(statusCode) \(reason)\r\n"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }
}

struct StarcatHTTPServerRequest: Sendable {
    private static let headerLimit = 64 * 1024
    private static let headerSeparator = Data("\r\n\r\n".utf8)

    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    init?(data: Data) throws {
        guard let separatorRange = data.range(of: Self.headerSeparator) else {
            guard data.count < Self.headerLimit else {
                throw StarcatHTTPServerError.badRequest("HTTP headers are too large.")
            }
            return nil
        }
        let headerData = data[..<separatorRange.lowerBound]
        guard headerData.count < Self.headerLimit,
              let headerText = String(data: headerData, encoding: .utf8)
        else { throw StarcatHTTPServerError.badRequest("Invalid HTTP headers.") }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ").map(String.init)
        guard requestParts.count >= 2 else { throw StarcatHTTPServerError.badRequest("Invalid HTTP request line.") }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let path = requestParts[1]
        let contentLengthHeader = headers.first { $0.key.lowercased() == "content-length" }?.value ?? "0"
        guard let contentLength = Int(contentLengthHeader), contentLength >= 0 else {
            throw StarcatHTTPServerError.badRequest("Invalid Content-Length.")
        }
        // 只按 body 字节计数；SDK multipart 的 HTTP 首部不占 System One 的 32 MiB 限额。
        let bodyLimit = (path == "/v1/systemone" ? 32 : 8) * 1024 * 1024
        guard contentLength <= bodyLimit else { throw StarcatHTTPServerError.payloadTooLarge }
        let bodyStart = separatorRange.upperBound
        guard data.endIndex - bodyStart >= contentLength else { return nil }

        self.method = requestParts[0]
        self.path = path
        self.headers = headers
        self.body = Data(data[bodyStart..<(bodyStart + contentLength)])
    }

    func header(_ name: String) -> String? {
        let lowercased = name.lowercased()
        return headers.first { $0.key.lowercased() == lowercased }?.value
    }
}

enum StarcatHTTPServerError: Error {
    case badRequest(String)
    case unauthorized
    case forbidden(String)
    case notFound
    case payloadTooLarge

    var httpData: Data {
        let status: Int
        let message: String
        switch self {
        case .badRequest(let value):
            status = 400
            message = value
        case .unauthorized:
            status = 401
            message = "Missing or invalid Bearer token."
        case .forbidden(let value):
            status = 403
            message = value
        case .notFound:
            status = 404
            message = "Use POST /mcp."
        case .payloadTooLarge:
            status = 413
            message = "HTTP request body exceeds the size limit."
        }

        let body = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data(#"{"error":"MCP request failed."}"#.utf8)
        let headers = status == 401 ? ["WWW-Authenticate": "Bearer"] : [:]
        return StarcatHTTPServerRouteResponse(statusCode: status, body: body, headers: headers).httpData
    }
}
