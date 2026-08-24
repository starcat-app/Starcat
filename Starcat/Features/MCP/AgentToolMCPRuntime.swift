//
//  AgentToolMCPRuntime.swift
//  Starcat
//
//  为单次 DeepSeek Harness Run 暴露当前 Agent 的业务工具。
//
//  这里不复用长期 Starcat MCP Registry：业务工具依赖冻结的 AgentRunContext 与同一
//  Run 内的轻量 payload，生命周期和权限边界都比通用 MCP 更窄。每次 initialize 都
//  重建 SDK session，以兼容 stateless HTTP client 的重连行为。
//

import Foundation
import MCP

@MainActor
final class AgentToolMCPRuntime: StarcatMCPHTTPRuntime {
    typealias ToolCallHandler = @Sendable (
        _ request: ExternalAgentToolRequest
    ) async -> ExternalAgentToolExecutionResult

    private let tools: [AgentToolDefinition]
    private let originValidator: OriginValidator
    private let toolCallHandler: ToolCallHandler
    private var session: Session?

    init(
        tools: [AgentToolDefinition],
        originValidator: OriginValidator,
        toolCallHandler: @escaping ToolCallHandler
    ) {
        self.tools = tools
        self.originValidator = originValidator
        self.toolCallHandler = toolCallHandler
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
                return .error(statusCode: 500, .internalError("Agent MCP runtime is unavailable."))
            }
            return await session.transport.handleRequest(request)
        } catch {
            return .error(statusCode: 500, .internalError(error.localizedDescription))
        }
    }

    private func makeSession() async throws -> Session {
        let transport = StatelessHTTPServerTransport(validationPipeline: StandardValidationPipeline(validators: [
            originValidator,
            AcceptHeaderValidator(mode: .jsonOnly),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
        ]))
        let server = Server(
            name: "starcat-agent",
            version: "1.0.0",
            title: "Starcat Agent Tools",
            instructions: "Use only the tools listed for this Starcat Agent run.",
            capabilities: .init(tools: .init(listChanged: false))
        )
        let registry = AgentToolMCPRegistry(tools: tools, toolCallHandler: toolCallHandler)
        await registry.register(on: server)
        try await server.start(transport: transport)
        return Session(server: server, transport: transport, registry: registry)
    }

    private static func isInitializeRequest(_ body: Data?) -> Bool {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = json["method"] as? String
        else { return false }
        return method == Initialize.name
    }

    private struct Session {
        let server: Server
        let transport: StatelessHTTPServerTransport
        // MCP Server 长期保存的 handler 使用弱引用，Registry 必须跟随 session 强持有。
        let registry: AgentToolMCPRegistry

        func shutdown() async {
            await server.stop()
            await transport.disconnect()
            _ = registry
        }
    }
}

@MainActor
private final class AgentToolMCPRegistry {
    private let tools: [AgentToolDefinition]
    private let allowedToolNames: Set<String>
    private let toolCallHandler: AgentToolMCPRuntime.ToolCallHandler

    init(
        tools: [AgentToolDefinition],
        toolCallHandler: @escaping AgentToolMCPRuntime.ToolCallHandler
    ) {
        self.tools = tools
        allowedToolNames = Set(tools.map(\.name))
        self.toolCallHandler = toolCallHandler
    }

    func register(on server: Server) async {
        await server.withMethodHandler(ListTools.self) { [weak self] _ in
            guard let self else { return .init(tools: []) }
            return await self.listTools()
        }
        await server.withMethodHandler(CallTool.self) { [weak self] parameters in
            guard let self else {
                return .init(
                    content: [.text(text: "Agent MCP registry is unavailable.", annotations: nil, _meta: nil)],
                    isError: true
                )
            }
            return await self.callTool(parameters)
        }
    }

    private func listTools() -> ListTools.Result {
        .init(tools: tools.compactMap { definition in
            guard let schema = try? Value(definition.inputSchema) else { return nil }
            return Tool(
                name: definition.name,
                title: definition.name,
                description: definition.description,
                inputSchema: schema,
                annotations: .init(
                    readOnlyHint: true,
                    openWorldHint: definition.permission == .openWorldRead
                )
            )
        })
    }

    private func callTool(_ parameters: CallTool.Parameters) async -> CallTool.Result {
        guard allowedToolNames.contains(parameters.name) else {
            return Self.errorResult("Tool is not allowed for this Agent: \(parameters.name)")
        }
        do {
            let input = try Self.agentValue(from: .object(parameters.arguments ?? [:]))
            let callID = UUID().uuidString.lowercased()
            let result = await toolCallHandler(ExternalAgentToolRequest(
                requestID: .string(callID),
                callID: callID,
                name: parameters.name,
                input: input,
                rawInput: try? input.jsonString()
            ))
            return try .init(
                content: [.text(text: result.modelText, annotations: nil, _meta: nil)],
                structuredContent: try Value(result.output),
                isError: result.isError
            )
        } catch {
            return Self.errorResult(error.localizedDescription)
        }
    }

    private static func agentValue(from value: Value) throws -> AgentJSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(AgentJSONValue.self, from: data)
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        .init(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            structuredContent: .object([
                "status": .string(AgentToolStatus.failed.rawValue),
                "summary": .string(message),
            ]),
            isError: true
        )
    }
}
