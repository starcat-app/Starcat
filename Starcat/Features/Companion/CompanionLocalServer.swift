//
//  CompanionLocalServer.swift
//  Starcat
//
//  Browser Plugin 本机 HTTP 服务骨架。
//
//  关键约束:
//  - 只绑定 IPv4 loopback, 不向局域网暴露 Starcat 私人数据;
//  - 所有业务请求必须通过全局 Starcat Local API Key;
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
    private let tagWriter: CompanionTagWriter?
    private let libraryStateWriter: CompanionLibraryStateWriter?
    private let actionHandler: CompanionActionHandler?
    private let starStateHandler: CompanionStarStateHandler?
    private let recommendationHandler: CompanionRecommendationHandler?
    private let eventHub: CompanionEventHub
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
        tagWriter: CompanionTagWriter? = nil,
        libraryStateWriter: CompanionLibraryStateWriter? = nil,
        actionHandler: CompanionActionHandler? = nil,
        starStateHandler: CompanionStarStateHandler? = nil,
        recommendationHandler: CompanionRecommendationHandler? = nil,
        eventHub: CompanionEventHub? = nil
    ) {
        self.configuration = configuration
        self.contextProvider = contextProvider
        self.noteWriter = noteWriter
        self.tagWriter = tagWriter
        self.libraryStateWriter = libraryStateWriter
        self.actionHandler = actionHandler
        self.starStateHandler = starStateHandler
        self.recommendationHandler = recommendationHandler
        self.eventHub = eventHub ?? CompanionEventHub()
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
            configuration.updateServerStatus(.failed(.invalidPort(port)))
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
                        guard self.listener === listener else { return }
                        self.listener = listener
                        self.configuration.updateServerStatus(.running)
                        AppLog.network.info(
                            "Browser Plugin Service started on 127.0.0.1:\(port, privacy: .public)"
                        )
                    case .failed(let error):
                        guard self.listener === listener else { return }
                        listener?.cancel()
                        self.listener = nil
                        let failure = Self.serverFailure(for: error, port: port)
                        self.configuration.updateServerStatus(.failed(failure))
                        AppLog.network.error(
                            "Browser Plugin Service failed on 127.0.0.1:\(port, privacy: .public): \(error.localizedDescription, privacy: .public)"
                        )
                        Self.recordUnexpectedListenerFailure(failure, error: error, port: port)
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
            let failure: CompanionConfiguration.ServerFailure
            if let networkError = error as? NWError {
                failure = Self.serverFailure(for: networkError, port: port)
            } else {
                failure = .listener(error.localizedDescription)
            }
            listener = nil
            configuration.updateServerStatus(.failed(failure))
            AppLog.network.error(
                "Browser Plugin Service failed on 127.0.0.1:\(port, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            Self.recordUnexpectedListenerFailure(failure, error: error, port: port)
        }
    }

    /// 端口冲突是用户可以直接处理的配置问题，必须从普通 listener 错误中单独识别。
    static func serverFailure(
        for error: NWError,
        port: UInt16
    ) -> CompanionConfiguration.ServerFailure {
        if case .posix(.EADDRINUSE) = error {
            return .portInUse(port)
        }
        return .listener(error.localizedDescription)
    }

    /// 端口范围和占用都能由用户改设置恢复；其余 listener 错误才属于开发者诊断。
    private static func recordUnexpectedListenerFailure(
        _ failure: CompanionConfiguration.ServerFailure,
        error: Error,
        port: UInt16
    ) {
        guard case .listener = failure else { return }
        DiagnosticLogStore.record(
            level: .error,
            visibility: .issue,
            category: "browser-plugin",
            operation: "browserPlugin.listener",
            message: "Browser Plugin local listener failed unexpectedly",
            underlying: DiagnosticEvent.summarize(error),
            context: ["port": String(port)]
        )
    }

    nonisolated private func receive(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 80 * 1024) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }
            Task { @MainActor in
                if await self.handleEventStreamIfNeeded(data, connection: connection) {
                    return
                }
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
        case ("GET", "/plugin/v1/ping"):
            return response(
                status: 200,
                body: CompanionPingResponse.ok,
                origin: origin
            )
        case ("GET", "/plugin/v1/repo-context"):
            return await repoContextResponse(request: request, origin: origin)
        case ("POST", "/plugin/v1/stars/state"):
            return await updateStarStateResponse(request: request, origin: origin)
        case ("POST", "/plugin/v1/recommendations/more"):
            return await recommendationsMoreResponse(request: request, origin: origin)
        case ("GET", "/plugin/v1/events"):
            return response(status: 426, body: ["error": "stream_required"], origin: origin)
        case ("PATCH", "/plugin/v1/notes"):
            return await saveNoteResponse(request: request, origin: origin)
        case ("PATCH", "/plugin/v1/tags"):
            return await saveTagsResponse(request: request, origin: origin)
        case ("PATCH", "/plugin/v1/library-state"):
            return await saveLibraryStateResponse(request: request, origin: origin)
        case ("POST", "/plugin/v1/actions/open"):
            return await openActionResponse(request: request, origin: origin)
        default:
            return response(status: 404, body: ["error": "not_found"], origin: origin)
        }
    }

    private func handleEventStreamIfNeeded(_ data: Data, connection: NWConnection) async -> Bool {
        let request: CompanionHTTPRequest
        do {
            request = try CompanionRequestParser.parse(data)
        } catch {
            return false
        }
        guard request.method == "GET", request.path == "/plugin/v1/events" else {
            return false
        }

        let origin = request.headers["origin"]
        guard isAllowedOrigin(origin) else {
            connection.send(content: response(status: 403, body: ["error": "origin_forbidden"], origin: nil), completion: .contentProcessed { _ in
                connection.cancel()
            })
            return true
        }
        guard request.headers["authorization"] == "Bearer \(configuration.token)" else {
            connection.send(content: response(status: 401, body: ["error": "unauthorized"], origin: origin), completion: .contentProcessed { _ in
                connection.cancel()
            })
            return true
        }

        let repoID = request.query["repo_id"].flatMap(Int64.init)
        let headers = eventStreamHeaders(origin: origin)
        connection.send(content: headers, completion: .contentProcessed { error in
            if error != nil {
                connection.cancel()
            }
        })
        connection.send(content: Data(": connected\n\n".utf8), completion: .contentProcessed { _ in })

        let clientID = eventHub.addClient(repoID: repoID) { [weak connection] event in
            guard let connection else { return }
            let data = Self.eventStreamData(for: event)
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard case .cancelled = state else {
                if case .failed = state {
                    Task { @MainActor in self?.eventHub.removeClient(clientID) }
                }
                return
            }
            Task { @MainActor in self?.eventHub.removeClient(clientID) }
        }
        return true
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
            Self.recordInternalFailure(endpoint: "repo-context", error: error)
            return response(status: 500, body: ["error": "internal_error"], origin: origin)
        }
    }

    private func updateStarStateResponse(request: CompanionHTTPRequest, origin: String?) async -> Data {
        guard let starStateHandler else {
            Self.recordMissingHandler(endpoint: "star-state")
            return response(status: 500, body: ["error": "internal_error"], origin: origin)
        }
        let payload: CompanionStarStateUpdateRequest
        do {
            payload = try Self.jsonDecoder.decode(CompanionStarStateUpdateRequest.self, from: request.body)
        } catch {
            return response(status: 400, body: ["error": "bad_json"], origin: origin)
        }

        do {
            let result = try await starStateHandler.apply(
                owner: payload.owner,
                repo: payload.repo,
                state: payload.state
            )
            return response(status: 200, body: result, origin: origin)
        } catch CompanionStarStateError.invalidRepoPath {
            return response(status: 400, body: ["error": "invalid_repo"], origin: origin)
        } catch StarActionError.notAuthenticated {
            // Bearer key 已通过，但 Starcat 尚未登录 GitHub；用 409 与本地 API 401 区分。
            return response(status: 409, body: ["error": "github_not_authenticated"], origin: origin)
        } catch {
            Self.recordInternalFailure(endpoint: "star-state", error: error)
            return response(status: 500, body: ["error": "star_state_update_failed"], origin: origin)
        }
    }

    private func recommendationsMoreResponse(request: CompanionHTTPRequest, origin: String?) async -> Data {
        guard let recommendationHandler else {
            return response(status: 500, body: ["error": "internal_error"], origin: origin)
        }
        let payload: CompanionRecommendationsMoreRequest
        do {
            payload = try Self.jsonDecoder.decode(CompanionRecommendationsMoreRequest.self, from: request.body)
        } catch {
            return response(status: 400, body: ["error": "bad_json"], origin: origin)
        }

        do {
            let result = try await recommendationHandler.loadMore(owner: payload.owner, repo: payload.repo)
            return response(status: 200, body: result, origin: origin)
        } catch CompanionRecommendationError.invalidRepoPath {
            return response(status: 400, body: ["error": "invalid_repo"], origin: origin)
        } catch CompanionRecommendationError.repoNotFound {
            return response(status: 404, body: ["error": "repo_not_found"], origin: origin)
        } catch CompanionRecommendationError.requiresPro {
            return response(status: 403, body: ["error": "requires_pro"], origin: origin)
        } catch {
            return response(status: 500, body: ["error": "recommendations_load_failed"], origin: origin)
        }
    }

    private func saveNoteResponse(request: CompanionHTTPRequest, origin: String?) async -> Data {
        guard let noteWriter else {
            Self.recordMissingHandler(endpoint: "notes")
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
            Self.recordInternalFailure(endpoint: "notes", error: error)
            return response(status: 500, body: ["error": "internal_error"], origin: origin)
        }
    }

    private func saveTagsResponse(request: CompanionHTTPRequest, origin: String?) async -> Data {
        guard let tagWriter else {
            Self.recordMissingHandler(endpoint: "tags")
            return response(status: 500, body: ["error": "internal_error"], origin: origin)
        }
        let payload: CompanionTagsUpdateRequest
        do {
            payload = try Self.jsonDecoder.decode(CompanionTagsUpdateRequest.self, from: request.body)
        } catch {
            return response(status: 400, body: ["error": "bad_json"], origin: origin)
        }

        do {
            let result = try await tagWriter.save(owner: payload.owner, repo: payload.repo, tagIDs: payload.tagIds)
            return response(
                status: 200,
                body: CompanionTagsUpdateResponse(schemaVersion: 1, status: "ok", tags: result.tags),
                origin: origin
            )
        } catch CompanionTagWriteError.repoNotFound {
            return response(status: 404, body: ["error": "repo_not_found"], origin: origin)
        } catch CompanionTagWriteError.repoNotStarred {
            return response(status: 403, body: ["error": "repo_not_starred"], origin: origin)
        } catch CompanionTagWriteError.unknownTagIDs {
            return response(status: 400, body: ["error": "unknown_tag"], origin: origin)
        } catch {
            Self.recordInternalFailure(endpoint: "tags", error: error)
            return response(status: 500, body: ["error": "internal_error"], origin: origin)
        }
    }

    private func saveLibraryStateResponse(request: CompanionHTTPRequest, origin: String?) async -> Data {
        guard let libraryStateWriter else {
            Self.recordMissingHandler(endpoint: "library-state")
            return response(status: 500, body: ["error": "internal_error"], origin: origin)
        }
        let payload: CompanionLibraryStateUpdateRequest
        do {
            payload = try Self.jsonDecoder.decode(CompanionLibraryStateUpdateRequest.self, from: request.body)
        } catch {
            return response(status: 400, body: ["error": "bad_json"], origin: origin)
        }

        do {
            let result = try await libraryStateWriter.save(
                owner: payload.owner,
                repo: payload.repo,
                state: payload.state,
                downgradeUsingStatus: payload.downgradeUsingStatus ?? false
            )
            return response(
                status: 200,
                body: CompanionLibraryStateUpdateResponse(
                    schemaVersion: 1,
                    status: "ok",
                    repoID: result.repoID,
                    libraryState: result.state.rawValue
                ),
                origin: origin
            )
        } catch CompanionLibraryStateWriteError.invalidState {
            return response(status: 400, body: ["error": "invalid_library_state"], origin: origin)
        } catch CompanionLibraryStateWriteError.repoNotFound {
            return response(status: 404, body: ["error": "repo_not_found"], origin: origin)
        } catch CompanionLibraryStateWriteError.usingRemovalRequiresConfirmation {
            return response(status: 409, body: ["error": "using_removal_requires_confirmation"], origin: origin)
        } catch {
            Self.recordInternalFailure(endpoint: "library-state", error: error)
            return response(status: 500, body: ["error": "internal_error"], origin: origin)
        }
    }

    private func openActionResponse(request: CompanionHTTPRequest, origin: String?) async -> Data {
        guard let actionHandler else {
            Self.recordMissingHandler(endpoint: "open-action")
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
        } catch CompanionActionError.requiresPro {
            return response(status: 403, body: ["error": "requires_pro"], origin: origin)
        } catch {
            Self.recordInternalFailure(endpoint: "open-action", error: error)
            return response(status: 500, body: ["error": "internal_error"], origin: origin)
        }
    }

    private static func recordInternalFailure(endpoint: String, error: Error) {
        guard !(error is CancellationError),
              !(error is NetworkError),
              !(error is URLError),
              !(error is EntitlementGateError) else {
            return
        }
        DiagnosticLogStore.record(
            level: .error,
            visibility: .issue,
            category: "browser-plugin",
            operation: "browserPlugin.internalRequest",
            message: "Browser Plugin local API returned an internal error",
            underlying: DiagnosticEvent.summarize(error),
            context: ["endpoint": endpoint]
        )
    }

    private static func recordMissingHandler(endpoint: String) {
        DiagnosticLogStore.record(
            level: .critical,
            visibility: .issue,
            category: "browser-plugin",
            operation: "browserPlugin.missingHandler",
            message: "Browser Plugin local API handler was not assembled",
            context: ["endpoint": endpoint]
        )
    }

    private func isAllowedOrigin(_ origin: String?) -> Bool {
        guard let origin else { return true }
        // Content script 在 GitHub 页面上下文里发起 loopback fetch 时，浏览器预检
        // 使用页面 Origin（https://github.com），不是固定扩展 Origin。这里放开
        // GitHub/Google 页面、Chrome 扩展和 Safari WebExtension；真正业务请求仍必须通过 Bearer token。
        // Google 搜索有大量国家域名，不能只放行 www.google.com，否则 google.com.hk
        // 这类实际搜索页会被 CORS 预检挡掉。
        return origin.hasPrefix("chrome-extension://")
            || origin.hasPrefix("safari-web-extension://")
            || origin == "https://github.com"
            || Self.isAllowedGoogleOrigin(origin)
    }

    private static func isAllowedGoogleOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin),
              url.scheme == "https",
              let host = url.host(percentEncoded: false)
        else { return false }
        var labels = host.lowercased().split(separator: ".").map(String.init)
        if labels.first == "www" {
            labels.removeFirst()
        }
        return labels.count >= 2 && labels.first == "google"
    }

    private func response(status: Int, body: some Encodable, origin: String?) -> Data {
        let bodyData = (try? Self.jsonEncoder.encode(body)) ?? Data("{}".utf8)
        return response(status: status, bodyData: bodyData, origin: origin)
    }

    private func response(status: Int, bodyData: Data, origin: String?) -> Data {
        let reason: String = switch status {
        case 200: "OK"
        case 204: "No Content"
        case 409: "Conflict"
        case 426: "Upgrade Required"
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

    private func eventStreamHeaders(origin: String?) -> Data {
        var headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/event-stream; charset=utf-8",
            "Cache-Control: no-cache",
            "Access-Control-Allow-Headers: Authorization, Content-Type",
            "Access-Control-Allow-Methods: GET, PATCH, POST, OPTIONS",
            "Access-Control-Allow-Private-Network: true",
            "Connection: keep-alive"
        ]
        if let origin {
            headers.append("Access-Control-Allow-Origin: \(origin)")
        }
        return Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private static func eventStreamData(for event: CompanionEventEnvelope) -> Data {
        let data = (try? jsonEncoder.encode(event)) ?? Data("{}".utf8)
        let payload = String(data: data, encoding: .utf8) ?? "{}"
        return Data("event: \(event.type)\ndata: \(payload)\n\n".utf8)
    }
}
