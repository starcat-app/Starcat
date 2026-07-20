//
//  StarcatMCPRuntime.swift
//  Starcat
//
//  MCP SDK Server 会话运行时。
//
//  Starcat 目前用 Streamable HTTP 的 stateless 模式接 Claude：HTTP 层没有持久
//  session id，但 Claude 断线重连时会重新发送 `initialize`。MCP Swift SDK 的
//  `Server` 初始化状态是单向状态机，同一个实例第二次 initialize 会返回 -32600。
//  本运行时把“一个 initialize 对应一套 SDK Server/Transport/Registry”固定下来，
//  既保留官方 SDK 的协议处理，也避免 fork SDK 或反射修改 private 状态。
//

import Foundation
import MCP

@MainActor
final class StarcatMCPRuntime {
    private let facade: StarcatMCPFacade
    private let writeFacade: StarcatMCPWriteFacade
    private let originValidator: OriginValidator
    private var session: Session?

    init(
        facade: StarcatMCPFacade,
        writeFacade: StarcatMCPWriteFacade,
        originValidator: OriginValidator = .localhost()
    ) {
        self.facade = facade
        self.writeFacade = writeFacade
        self.originValidator = originValidator
    }

    func start() async throws {
        session = try await makeSession()
    }

    func shutdown() async {
        let current = session
        session = nil
        await current?.shutdown()
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            if Self.isInitializeRequest(request.body) {
                await shutdown()
                session = try await makeSession()
            } else if session == nil {
                session = try await makeSession()
            }
            guard let session else {
                return .error(statusCode: 500, .internalError("MCP runtime is unavailable."))
            }
            return await session.transport.handleRequest(request)
        } catch {
            return .error(statusCode: 500, .internalError(error.localizedDescription))
        }
    }

    private func makeSession() async throws -> Session {
        // SDK 默认只允许 localhost Host。可信网络模式会使用 Mac 的 Bonjour hostname，
        // 因此由 Service 注入精确 allowlist；仍保留其它标准 HTTP 校验，不能用
        // `OriginValidator.disabled` 绕过 DNS rebinding 防护。
        let validationPipeline = StandardValidationPipeline(validators: [
            originValidator,
            AcceptHeaderValidator(mode: .jsonOnly),
            ContentTypeValidator(),
            ProtocolVersionValidator()
        ])
        let transport = StatelessHTTPServerTransport(validationPipeline: validationPipeline)
        let server = Server(
            name: "starcat",
            version: "0.3.0",
            title: "Starcat",
            instructions: "Use starcat.get_capabilities before multi-step workflows, starcat.get_overview_statistics for common counts, and starcat.get_repo_context for one-repository reads. Write tools are Pro-only, local-data-only, settings-gated, and audited. Use dry_run before destructive writes. Never expose private notes unless the capability is enabled.",
            capabilities: .init(
                resources: .init(listChanged: false),
                tools: .init(listChanged: false)
            )
        )
        let registry = StarcatMCPToolRegistry(facade: facade, writeFacade: writeFacade)

        // `Server.withMethodHandler` 会长期保存 handler 闭包。registry 必须由
        // Session 强持有到 server 停止，否则 handler 内的弱引用会变 nil，
        // Claude 只能看到空工具列表或 "registry unavailable"。
        await registry.register(on: server)
        try await server.start(transport: transport)
        return Session(server: server, transport: transport, registry: registry)
    }

    private static func isInitializeRequest(_ body: Data?) -> Bool {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = json["method"] as? String
        else {
            return false
        }
        return method == Initialize.name
    }

    private struct Session {
        let server: Server
        let transport: StatelessHTTPServerTransport
        let registry: StarcatMCPToolRegistry

        func shutdown() async {
            await server.stop()
            await transport.disconnect()
            _ = registry
        }
    }
}
