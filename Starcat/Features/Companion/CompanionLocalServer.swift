//
//  CompanionLocalServer.swift
//  Starcat
//
//  Chrome Companion 本机 HTTP 服务骨架。
//
//  关键约束:
//  - 只绑定 IPv4 loopback, 不向局域网暴露 Starcat 私人数据;
//  - 所有业务请求必须通过 Companion Bearer Token;
//  - CORS Private Network Access 预检不要求 token, 但仍限制 Origin;
//  - 当前文件只实现 ping 与通用安全外壳, repo-context/notes/actions 后续增量接入。
//

import Foundation
import Network

@MainActor
final class CompanionLocalServer {
    private let configuration: CompanionConfiguration
    private let contextProvider: CompanionContextProvider
    private let noteWriter: CompanionNoteWriter?
    private let actionHandler: CompanionActionHandler?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.starcat.companion.local-server")
    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    init(
        configuration: CompanionConfiguration,
        contextProvider: CompanionContextProvider = CompanionContextProvider { _, _ in nil },
        noteWriter: CompanionNoteWriter? = nil,
        actionHandler: CompanionActionHandler? = nil
    ) {
        self.configuration = configuration
        self.contextProvider = contextProvider
        self.noteWriter = noteWriter
        self.actionHandler = actionHandler
    }

    func start() {
        guard listener == nil, configuration.isEnabled, !TestEnvironment.isRunning else { return }
        configuration.updateServerStatus(.starting)
        bind(port: configuration.port)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        configuration.updateServerStatus(.stopped)
    }

    private func bind(port: UInt16) {
        guard CompanionConfiguration.allowedPortRange.contains(Int(port)),
              let nwPort = NWEndpoint.Port(rawValue: port) else {
            configuration.updateServerStatus(.failed)
            return
        }

        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.receive(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.listener = listener
                        self.configuration.updateBoundPort(port)
                        self.configuration.updateServerStatus(.running)
                    case .failed:
                        listener?.cancel()
                        if port < UInt16(CompanionConfiguration.allowedPortRange.upperBound) {
                            self.bind(port: port + 1)
                        } else {
                            self.configuration.updateServerStatus(.failed)
                        }
                    case .cancelled:
                        if self.listener === listener { self.listener = nil }
                    default:
                        break
                    }
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            if port < UInt16(CompanionConfiguration.allowedPortRange.upperBound) {
                bind(port: port + 1)
            } else {
                configuration.updateServerStatus(.failed)
            }
        }
    }

    nonisolated private func receive(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 80 * 1024) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }
            Task { @MainActor in
                let response = await self.handle(data)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    func handle(_ data: Data) async -> Data {
        let request: CompanionHTTPRequest
        do {
            request = try CompanionRequestParser.parse(data)
        } catch {
            return response(status: 400, body: ["error": "bad_request"], origin: nil)
        }

        let origin = request.headers["origin"]
        guard isAllowedOrigin(origin) else {
            return response(status: 403, body: ["error": "origin_forbidden"], origin: nil)
        }

        if request.method == "OPTIONS" {
            return response(status: 204, bodyData: Data(), origin: origin)
        }

        guard request.headers["authorization"] == "Bearer \(configuration.token)" else {
            return response(status: 401, body: ["error": "unauthorized"], origin: origin)
        }

        switch (request.method, request.path) {
        case ("GET", "/local/v1/ping"):
            return response(
                status: 200,
                body: CompanionPingResponse.ok,
                origin: origin
            )
        case ("GET", "/local/v1/repo-context"):
            return await repoContextResponse(request: request, origin: origin)
        case ("PATCH", "/local/v1/notes"):
            return await saveNoteResponse(request: request, origin: origin)
        case ("POST", "/local/v1/actions/open"):
            return await openActionResponse(request: request, origin: origin)
        default:
            return response(status: 404, body: ["error": "not_found"], origin: origin)
        }
    }

    private func repoContextResponse(request: CompanionHTTPRequest, origin: String?) async -> Data {
        guard let owner = request.query["owner"], let repo = request.query["repo"] else {
            return response(status: 400, body: ["error": "missing_repo"], origin: origin)
        }
        do {
            let context = try await contextProvider.context(owner: owner, repo: repo)
            return response(status: 200, body: context, origin: origin)
        } catch CompanionContextError.invalidRepoPath {
            return response(status: 400, body: ["error": "invalid_repo"], origin: origin)
        } catch {
            return response(status: 500, body: ["error": "internal_error"], origin: origin)
        }
    }

    private func saveNoteResponse(request: CompanionHTTPRequest, origin: String?) async -> Data {
        guard let noteWriter else {
            return response(status: 500, body: ["error": "internal_error"], origin: origin)
        }
        let payload: CompanionNoteSaveRequest
        do {
            payload = try Self.jsonDecoder.decode(CompanionNoteSaveRequest.self, from: request.body)
        } catch {
            return response(status: 400, body: ["error": "bad_json"], origin: origin)
        }

        do {
            let note = try await noteWriter.save(owner: payload.owner, repo: payload.repo, content: payload.content)
            return response(
                status: 200,
                body: CompanionNoteSaveResponse(schemaVersion: 1, status: "ok", note: note),
                origin: origin
            )
        } catch CompanionNoteWriteError.contentTooLarge {
            return response(status: 400, body: ["error": "content_too_large"], origin: origin)
        } catch CompanionNoteWriteError.repoNotFound {
            return response(status: 404, body: ["error": "repo_not_found"], origin: origin)
        } catch CompanionNoteWriteError.repoNotStarred {
            return response(status: 403, body: ["error": "repo_not_starred"], origin: origin)
        } catch {
            return response(status: 500, body: ["error": "internal_error"], origin: origin)
        }
    }

    private func openActionResponse(request: CompanionHTTPRequest, origin: String?) async -> Data {
        guard let actionHandler else {
            return response(status: 500, body: ["error": "internal_error"], origin: origin)
        }
        let payload: CompanionOpenActionRequest
        do {
            payload = try Self.jsonDecoder.decode(CompanionOpenActionRequest.self, from: request.body)
        } catch {
            return response(status: 400, body: ["error": "bad_json"], origin: origin)
        }

        do {
            try await actionHandler.open(owner: payload.owner, repo: payload.repo, action: payload.action)
            return response(
                status: 200,
                body: CompanionOpenActionResponse(schemaVersion: 1, status: "ok", action: payload.action),
                origin: origin
            )
        } catch CompanionActionError.repoNotFound {
            return response(status: 404, body: ["error": "repo_not_found"], origin: origin)
        } catch CompanionActionError.repoNotStarred {
            return response(status: 403, body: ["error": "repo_not_starred"], origin: origin)
        } catch {
            return response(status: 500, body: ["error": "internal_error"], origin: origin)
        }
    }

    private func isAllowedOrigin(_ origin: String?) -> Bool {
        guard let origin else { return true }
        return origin.hasPrefix("chrome-extension://")
    }

    private func response(status: Int, body: some Encodable, origin: String?) -> Data {
        let bodyData = (try? Self.jsonEncoder.encode(body)) ?? Data("{}".utf8)
        return response(status: status, bodyData: bodyData, origin: origin)
    }

    private func response(status: Int, bodyData: Data, origin: String?) -> Data {
        let reason: String = switch status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 500: "Internal Server Error"
        default: "Internal Server Error"
        }
        var headers = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: application/json; charset=utf-8",
            "Content-Length: \(bodyData.count)",
            "Access-Control-Allow-Headers: Authorization, Content-Type",
            "Access-Control-Allow-Methods: GET, PATCH, POST, OPTIONS",
            "Access-Control-Allow-Private-Network: true",
            "Connection: close"
        ]
        if let origin {
            headers.append("Access-Control-Allow-Origin: \(origin)")
        }

        var response = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        response.append(bodyData)
        return response
    }
}
