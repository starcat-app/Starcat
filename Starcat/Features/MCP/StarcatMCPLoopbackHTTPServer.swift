//
//  StarcatMCPLoopbackHTTPServer.swift
//  Starcat
//
//  `StatelessHTTPServerTransport` 的本机 HTTP 适配器。
//
//  MCP Swift SDK 的 server transport 是 framework-agnostic：它负责把 HTTPRequest 转成
//  JSON-RPC，但不负责监听端口。Starcat 是 macOS 原生 App，不需要为了一个 loopback
//  端口引入 NIO/Vapor，因此这里用 Network.framework 写一层极薄 adapter。
//
//  关键约束：
//  - 只监听 `127.0.0.1`，不开放局域网 host 配置；
//  - P0 使用 stateless HTTP，一次连接处理一个请求，不支持 SSE/server push；
//  - 请求体上限 8 MiB，避免 agent 误传大 payload 撑爆 App 内存。
//

import Foundation
import MCP
import Network

@MainActor
final class StarcatMCPLoopbackHTTPServer {
    private let port: Int
    private let transport: StatelessHTTPServerTransport
    private let requestValidator: @MainActor (StarcatHTTPServerRequest) -> StarcatHTTPServerError?
    private let queue = DispatchQueue(label: "com.starcat.mcp.http")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(
        port: Int,
        transport: StatelessHTTPServerTransport,
        requestValidator: @escaping @MainActor (StarcatHTTPServerRequest) -> StarcatHTTPServerError?
    ) {
        self.port = port
        self.transport = transport
        self.requestValidator = requestValidator
    }

    func start() throws {
        guard listener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw StarcatMCPError.invalidArguments("Invalid MCP port: \(port)")
        }
        let parameters = NWParameters.tcp
        // ⚠️ macOS 26 (Darwin 25) Network.framework 校验更严格：
        // requiredLocalEndpoint 与 NWListener(using:on:) 同时指定相同端口会触发
        // NWError.posix(.EINVAL)（Invalid argument）。
        // 端口统一交由 `on:` 参数控制，requiredLocalEndpoint 端口用 .any，
        // 仍限制监听地址为 127.0.0.1，安全边界不变。
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address.loopback), port: .any)

        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.accept(connection)
            }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                AppLog.network.error("MCP HTTP listener failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
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
            let response = await transport.handleRequest(httpRequest)
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
