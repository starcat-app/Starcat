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
//  - 默认只监听 `127.0.0.1`；可信网络模式必须传入独立 TLS identity 才能绑定所有接口；
//  - P0 使用 stateless HTTP，一次连接处理一个请求，不支持 SSE/server push；
//  - 请求体上限 8 MiB，避免 agent 误传大 payload 撑爆 App 内存。
//

import Foundation
import MCP
import Network
import Security

@MainActor
final class StarcatMCPLoopbackHTTPServer {
    private let port: Int
    private let runtime: any StarcatMCPHTTPRuntime
    private let tlsIdentity: SecIdentity?
    private let requestValidator: @MainActor (StarcatHTTPServerRequest) -> StarcatHTTPServerError?
    private let routeHandler: @MainActor (StarcatHTTPServerRequest) async -> StarcatHTTPServerRouteResponse?
    private let queue = DispatchQueue(label: "com.starcat.mcp.http")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var startupContinuation: CheckedContinuation<Int, Error>?

    init(
        port: Int,
        runtime: any StarcatMCPHTTPRuntime,
        tlsIdentity: SecIdentity? = nil,
        requestValidator: @escaping @MainActor (StarcatHTTPServerRequest) -> StarcatHTTPServerError?,
        routeHandler: @escaping @MainActor (StarcatHTTPServerRequest) async -> StarcatHTTPServerRouteResponse? = { _ in nil }
    ) {
        self.port = port
        self.runtime = runtime
        self.tlsIdentity = tlsIdentity
        self.requestValidator = requestValidator
        self.routeHandler = routeHandler
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
        let listener: NWListener
        if let tlsIdentity {
            let tlsOptions = NWProtocolTLS.Options()
            guard let networkIdentity = sec_identity_create(tlsIdentity) else {
                throw StarcatMCPError.invalidArguments("Unable to create MCP TLS identity")
            }
            sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, networkIdentity)
            sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv13)
            let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
            // 远程模式显式绑定 wildcard；只有配置完成 TLS identity 后才会走到这里。
            listener = try NWListener(using: parameters, on: nwPort)
        } else {
            let parameters = NWParameters.tcp
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

    /// 临时 Runtime Bridge 必须等 listener 真正进入 ready 才能启动 Harness；否则
    /// MCP client 的首次严格同步可能先于 socket bind，导致本轮模型拿不到任何工具。
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
            }
            if case .posix(.EADDRINUSE) = error { return }
            DiagnosticLogStore.record(
                level: .error,
                visibility: .issue,
                category: "mcp",
                operation: "mcp.listenerRuntime",
                message: "MCP HTTP listener failed after startup",
                underlying: DiagnosticEvent.summarize(error),
                context: ["port": String(diagnosticPort)]
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
        do {
            let request = try await readRequest(from: connection)
            // `/pairing/exchange` 在认证前处理：它只接受五分钟有效的一次性 secret，
            // 成功后仍需用户在 App 内确认。其它路径继续走原有 Bearer 校验。
            if let routed = await routeHandler(request) {
                send(Self.httpData(for: routed), on: connection)
                return
            }
            if let error = requestValidator(request) {
                send(error.httpData, on: connection)
                return
            }

            let httpRequest = HTTPRequest(
                method: request.method,
                headers: request.headers,
                body: request.body,
                path: request.path
            )
            let response = await runtime.handle(httpRequest)
            send(Self.httpData(for: response), on: connection)
        } catch {
            send(StarcatHTTPServerError.badRequest(error.localizedDescription).httpData, on: connection)
        }
    }

    private func readRequest(from connection: NWConnection) async throws -> StarcatHTTPServerRequest {
        var buffer = Data()
        let maxBytes = 8 * 1024 * 1024

        while buffer.count < maxBytes {
            let chunk = try await receiveChunk(from: connection)
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)
            if let request = StarcatHTTPServerRequest(data: buffer) {
                return request
            }
        }
        throw StarcatMCPError.invalidArguments("Invalid or oversized HTTP request")
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

    private static func httpData(for response: HTTPResponse) -> Data {
        let body = response.bodyData ?? Data()
        var headers = response.headers
        headers["Content-Length"] = "\(body.count)"
        if headers["Content-Type"] == nil {
            headers["Content-Type"] = "application/json"
        }
        headers["Connection"] = "close"

        let reason: String
        switch response.statusCode {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        default: reason = "Error"
        }

        var head = "HTTP/1.1 \(response.statusCode) \(reason)\r\n"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"

        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    private static func httpData(for response: StarcatHTTPServerRouteResponse) -> Data {
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Content-Type"] = headers["Content-Type"] ?? "application/json"
        headers["Connection"] = "close"

        let reason: String
        switch response.statusCode {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 409: reason = "Conflict"
        default: reason = "Error"
        }
        var head = "HTTP/1.1 \(response.statusCode) \(reason)\r\n"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(response.body)
        return out
    }
}

/// MCP 以外的窄路由响应。目前只用于一次性设备配对，不扩展成第二套业务 API。
struct StarcatHTTPServerRouteResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    init(statusCode: Int, body: Data, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
    }
}

struct StarcatHTTPServerRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    init?(data: Data) {
        guard let separatorRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data[..<separatorRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ").map(String.init)
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let bodyStart = data.distance(from: data.startIndex, to: separatorRange.upperBound)
        let contentLengthHeader = headers.first { $0.key.lowercased() == "content-length" }?.value
        let contentLength = contentLengthHeader.flatMap(Int.init) ?? 0
        guard data.count >= bodyStart + contentLength else { return nil }

        self.method = requestParts[0]
        self.path = requestParts[1]
        self.headers = headers
        self.body = Data(data[bodyStart..<(bodyStart + contentLength)])
    }

    func header(_ name: String) -> String? {
        let lowercased = name.lowercased()
        return headers.first { $0.key.lowercased() == lowercased }?.value
    }
}

enum StarcatHTTPServerError {
    case badRequest(String)
    case unauthorized
    case forbidden(String)
    case notFound

    var httpData: Data {
        let status: Int
        let reason: String
        let message: String
        switch self {
        case .badRequest(let value):
            status = 400
            reason = "Bad Request"
            message = value
        case .unauthorized:
            status = 401
            reason = "Unauthorized"
            message = "Missing or invalid Bearer token."
        case .forbidden(let value):
            status = 403
            reason = "Forbidden"
            message = value
        case .notFound:
            status = 404
            reason = "Not Found"
            message = "Use POST /mcp."
        }

        let body = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data(#"{"error":"MCP request failed."}"#.utf8)
        let head = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: application/json\r
        Content-Length: \(body.count)\r
        WWW-Authenticate: Bearer\r
        Connection: close\r
        \r
        """
        var out = Data(head.utf8)
        out.append(body)
        return out
    }
}
