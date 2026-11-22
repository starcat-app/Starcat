//
//  StarcatMCPService.swift
//  Starcat
//
//  Starcat 本机 MCP Service 协调器。
//
//  生命周期由 Settings 与 AppDependencies 驱动：
//  - 用户开启后，只在 Pro 权益有效时监听 HTTP；默认回环，可扩展到网络接口；
//  - Bearer token 来自全局 Starcat Local API Key，设置页集中在「集成」管理；
//  - 每个 HTTP 请求都会重新检查开关 / Pro / token，防止订阅状态变化后旧连接继续放行。
//

import Darwin
import Foundation
import MCP
import Observation
import SystemConfiguration

@MainActor
@Observable
final class StarcatMCPService {
    enum State: Equatable {
        case stopped
        case running(port: Int)
        case failed(String)
    }

    private let settings: AppSettings
    private let entitlementGate: EntitlementGate
    private let localAPIKeyStore: StarcatLocalAPIKeyStore
    let deviceStore: StarcatMCPDeviceStore
    private let facade: StarcatMCPFacade
    private let writeFacade: StarcatMCPWriteFacade
    private let notificationService: ReleaseNotificationService?
    private let decisionSystemOneService: DecisionSystemOneService?
    private var runtime: StarcatMCPRuntime?
    private var httpServer: StarcatMCPLoopbackHTTPServer?
    private var activeRemoteConnections = false
    private var startupTask: Task<Void, Never>?
    private var lifecycleGeneration = 0

    private(set) var state: State = .stopped
    private(set) var remoteEndpointURL: String?
    var bearerToken: String { localAPIKeyStore.apiKey }

    /// 为一个外部 Agent Run 创建独立的只读 MCP Server。
    ///
    /// 该入口不依赖设置页 MCP 开关，也不复用长期 API Key：外部 Runtime 已经过
    /// Direct 分发门控，本租约再用随机端口、单次 Token 与工具 allowlist 收窄权限。
    /// Run 结束后 `shutdown` 同时关闭 listener 与 MCP SDK session。
    func makeTransientBridge(
        toolSet: ExternalAgentMCPToolSet
    ) async throws -> ExternalAgentMCPLease {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var lastError: Error?
        for _ in 0..<5 {
            let port = try StarcatMCPPortAvailability.availableDynamicPort()
            let runtime = try makeTransientRuntime(toolSet: toolSet, port: port)
            try await runtime.start()
            let httpServer = StarcatMCPLoopbackHTTPServer(
                port: port,
                runtime: runtime,
                requestValidator: { request in
                    guard request.path == "/mcp" else { return .notFound }
                    guard let authorization = request.header("Authorization"),
                          authorization == "Bearer \(token)"
                    else { return .unauthorized }
                    return nil
                }
            )
            do {
                let boundPort = try await httpServer.startAndWaitUntilReady()
                let connection = ExternalAgentMCPConnection(
                    endpointURL: URL(string: "http://127.0.0.1:\(boundPort)/mcp")!,
                    bearerToken: token
                )
                return ExternalAgentMCPLease(connection: connection) {
                    await MainActor.run { httpServer.stop() }
                    await runtime.shutdown()
                }
            } catch {
                lastError = error
                httpServer.stop()
                await runtime.shutdown()
            }
        }
        throw lastError ?? StarcatMCPError.invalidArguments(
            "Unable to start the transient Starcat MCP bridge."
        )
    }

    private func makeTransientRuntime(
        toolSet: ExternalAgentMCPToolSet,
        port: Int
    ) throws -> any StarcatMCPHTTPRuntime {
        let originValidator = makeOriginValidator(port: port)
        switch toolSet {
        case .starcatReadOnly(let allowedToolNames):
            guard !allowedToolNames.isEmpty else {
                throw StarcatMCPError.invalidArguments("Transient MCP tool allowlist must not be empty.")
            }
            let disallowed = allowedToolNames.subtracting(StarcatMCPToolRegistry.readOnlyToolNames)
            guard disallowed.isEmpty else {
                throw StarcatMCPError.invalidArguments(
                    "Transient MCP bridge rejected non-read-only tools: \(disallowed.sorted().joined(separator: ", "))"
                )
            }
            return StarcatMCPRuntime(
                facade: facade,
                writeFacade: writeFacade,
                originValidator: originValidator,
                allowedToolNames: allowedToolNames,
                exposesResources: false
            )
        case .agent(let tools, let call):
            guard !tools.isEmpty else {
                throw StarcatMCPError.invalidArguments("Transient Agent MCP tools must not be empty.")
            }
            guard let nonReadTool = tools.first(where: { !$0.permission.isAutomaticRead }) else {
                return AgentToolMCPRuntime(
                    tools: tools,
                    originValidator: originValidator,
                    toolCallHandler: call
                )
            }
            throw StarcatMCPError.invalidArguments(
                "Transient Agent MCP bridge rejected non-read-only tool: \(nonReadTool.name)"
            )
        }
    }

    init(
        settings: AppSettings,
        entitlementGate: EntitlementGate,
        localAPIKeyStore: StarcatLocalAPIKeyStore = .shared,
        deviceStore: StarcatMCPDeviceStore,
        facade: StarcatMCPFacade,
        writeFacade: StarcatMCPWriteFacade,
        notificationService: ReleaseNotificationService? = nil,
        decisionSystemOneService: DecisionSystemOneService? = nil
    ) {
        self.settings = settings
        self.entitlementGate = entitlementGate
        self.localAPIKeyStore = localAPIKeyStore
        self.deviceStore = deviceStore
        self.facade = facade
        self.writeFacade = writeFacade
        self.notificationService = notificationService
        self.decisionSystemOneService = decisionSystemOneService
    }

    var endpointURL: String? {
        guard case .running(let port) = state else { return nil }
        return Self.makeEndpointURL(port: port)
    }

    static func makeEndpointURL(port: Int, host: String = "127.0.0.1") -> String {
        "http://\(host):\(port)/mcp"
    }

    /// 记录 listener 启动时的网络地址。允许 IP 直连，同时保留稳定的 Bonjour 配对地址。
    static func localIPv4Hosts() -> [String] {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let addresses else { return [] }
        defer { freeifaddrs(addresses) }
        return sequence(first: addresses, next: { $0.pointee.ifa_next }).compactMap { entry in
            let interface = entry.pointee
            guard interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = interface.ifa_addr,
                  address.pointee.sa_family == AF_INET else { return nil }
            var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { return nil }
            return String(decoding: host.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        }
    }

    var cliInstallCommand: String {
        MCPAgentSetupPrompt.cliInstallCommand
    }

    var cliAgentInstallPrompt: String {
        MCPAgentSetupPrompt.cliAgentInstall
    }

    var cliVerificationCommand: String {
        MCPAgentSetupPrompt.cliVerificationCommand
    }

    var claudeMCPConfiguration: String {
        MCPAgentSetupPrompt.claudeMCPConfiguration
    }

    var codexMCPConfiguration: String {
        MCPAgentSetupPrompt.codexMCPConfiguration
    }

    var mcpAgentSetupPrompt: String {
        MCPAgentSetupPrompt.mcpAgentSetup
    }

    var skillManualInstall: String {
        MCPAgentSetupPrompt.skillManualInstall
    }

    var skillAgentInstallPrompt: String {
        MCPAgentSetupPrompt.skillAgentInstall
    }

    /// 手工入口复制可直接执行的完整命令。invitation secret 只有五分钟、单次有效，
    /// 且兑换仍需 App 内确认；以这三层约束换取“粘贴后按 Enter”的配对体验。
    func createPairingCommand() throws -> String {
        MCPAgentSetupPrompt.pairingCommand(invitationURI: try createPairingInvitationURI())
    }

    /// 单独生成跨设备邀请，本机邀请始终可在关闭远程连接后继续使用。
    func createRemotePairingCommand() throws -> String {
        guard let remoteEndpointURL else { throw StarcatMCPError.disabled }
        return MCPAgentSetupPrompt.pairingCommand(
            invitationURI: try deviceStore.createInvitation(endpoint: remoteEndpointURL)
        )
    }

    /// 每次点击都创建新的五分钟 invitation，避免手工配对与 Agent 配对复用 secret。
    func createPairingAgentInstruction() throws -> String {
        MCPAgentSetupPrompt.pairAgent(invitationURI: try createPairingInvitationURI())
    }

    /// 完整配置同样按点击生成独立 invitation；即使用户先复制过单独的配对提示词，
    /// 两条流程也不会共享或重复消费同一个 secret。
    func createCompleteAgentSetupInstruction() throws -> String {
        MCPAgentSetupPrompt.completeAgentSetup(invitationURI: try createPairingInvitationURI())
    }

    /// invitation 只用于兑换逐设备 token，不能直接调用 MCP。
    private func createPairingInvitationURI() throws -> String {
        guard let endpointURL else {
            throw StarcatMCPError.disabled
        }
        return try deviceStore.createInvitation(endpoint: endpointURL)
    }

    func refreshForCurrentSettings() {
        guard settings.mcpServiceEnabled else {
            stop()
            return
        }
        guard entitlementGate.isProUser else {
            stop()
            state = .failed(String.l10n("settings.mcp.status.requiresPro"))
            return
        }
        start()
    }

    /// 设置页「重启」的显式入口。
    ///
    /// `start()` 会在“已经运行且端口没变”时直接返回，适合自动 refresh；
    /// 但用户点击重启时需要真实释放旧 listener，再做端口占用预检并重新启动。
    func restartForCurrentSettings() {
        stop()
        refreshForCurrentSettings()
    }

    func start() {
        guard settings.mcpServiceEnabled else {
            state = .stopped
            return
        }
        guard entitlementGate.isProUser else {
            stop()
            state = .failed(StarcatMCPError.requiresPro.localizedDescription)
            return
        }
        if case .running(let currentPort) = state,
           currentPort == settings.mcpServicePort,
           activeRemoteConnections == settings.mcpAllowRemoteConnections {
            return
        }
        stop()

        let port = settings.mcpServicePort

        // 端口范围校验同步做（纯数学检查，不需要等旧 listener 释放）
        guard (1024...65_535).contains(port) else {
            state = .failed(String(format: String.l10n("settings.mcp.port.error.invalidFormat"), port))
            return
        }

        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        let allowsRemoteConnections = settings.mcpAllowRemoteConnections
        var remoteHosts: [String] = []
        if allowsRemoteConnections {
            if let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty {
                remoteHosts.append("\(name).local")
            }
            remoteHosts.append(contentsOf: Self.localIPv4Hosts())
        }
        let remoteHost = remoteHosts.first
        if allowsRemoteConnections {
            // 兼顾旧 profile 保存的系统 DNS 名称，但新邀请优先使用本机公布的地址。
            remoteHosts.append(ProcessInfo.processInfo.hostName)
        }
        let originValidator = makeOriginValidator(port: port, remoteHosts: remoteHosts)
        let runtime = StarcatMCPRuntime(
            facade: facade,
            writeFacade: writeFacade,
            originValidator: originValidator
        )

        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // NWListener.cancel() 是异步的，重启场景下旧 listener 的 socket
                // 释放有延迟；这里重试最多 10 次（每次等 200ms，累计 2s），
                // 避免用户看到「端口占用」误报。
                try Task.checkCancellation()
                try await waitForPortAvailable(port: port)
                try Task.checkCancellation()

                try await runtime.start()
                try Task.checkCancellation()
                let httpServer = StarcatMCPLoopbackHTTPServer(
                    port: port,
                    runtime: runtime,
                    allowsRemoteConnections: allowsRemoteConnections,
                    requestValidator: { [weak self] request in
                        self?.validate(request)
                    },
                    routeHandler: { [weak self] request in
                        await self?.handlePairingRoute(request)
                    },
                    publicRouteHandler: { [weak self] request in
                        await self?.handlePublicRoute(request, originValidator: originValidator)
                    }
                )
                self.httpServer = httpServer
                let boundPort = try await httpServer.startAndWaitUntilReady()

                guard !Task.isCancelled, generation == self.lifecycleGeneration else {
                    httpServer.stop()
                    await runtime.shutdown()
                    return
                }

                self.runtime = runtime
                self.activeRemoteConnections = allowsRemoteConnections
                self.remoteEndpointURL = remoteHost.map { Self.makeEndpointURL(port: boundPort, host: $0) }
                self.state = .running(port: boundPort)
                AppLog.network.info("MCP Service started (remote=\(self.activeRemoteConnections, privacy: .public), port=\(port, privacy: .public))")
            } catch is CancellationError {
                await runtime.shutdown()
            } catch {
                await runtime.shutdown()
                guard generation == self.lifecycleGeneration else { return }
                self.httpServer?.stop()
                self.httpServer = nil
                self.state = .failed(error.localizedDescription)
                AppLog.network.error("MCP Service failed: \(error.localizedDescription, privacy: .public)")
                if let mcpError = error as? StarcatMCPError,
                   case .invalidArguments = mcpError {
                    // 非法端口或端口占用可由用户在设置页修改，不进入开发者诊断。
                } else {
                    DiagnosticLogStore.record(
                        level: .error,
                        visibility: .issue,
                        category: "mcp",
                        operation: "mcp.start",
                        message: "MCP runtime failed to start",
                        summary: .serviceUnavailable,
                        impact: .blocked,
                        underlying: DiagnosticEvent.summarize(error),
                        context: ["port": String(port)], error: error
                    )
                }
                await self.notificationService?.dispatchMCPFailure(message: error.localizedDescription)
            }
        }
    }

    func stop() {
        lifecycleGeneration += 1
        deviceStore.invalidatePendingPairing()
        startupTask?.cancel()
        startupTask = nil
        httpServer?.stop()
        httpServer = nil
        remoteEndpointURL = nil
        activeRemoteConnections = false
        let runtime = runtime
        self.runtime = nil
        if runtime != nil {
            Task {
                await runtime?.shutdown()
            }
        }
        state = .stopped
    }

    /// 端口可用性预检，带重试。
    ///
    /// `NWListener.cancel()` 是异步操作，重启场景下旧 listener 的 socket 释放
    /// 有延迟（通常 < 50ms）。这里用 POSIX `bind` 做同步探测，连续失败则等 200ms
    /// 重试，最多 10 次（累计 2s）。真正被其他进程占用时，10 次后仍会正确报错。
    private func waitForPortAvailable(
        port: Int,
        maxRetries: Int = 10,
        delayInMS: UInt64 = 200
    ) async throws {
        for attempt in 0..<maxRetries {
            if let message = StarcatMCPPortAvailability.unavailableMessage(for: port) {
                if attempt < maxRetries - 1 {
                    try await Task.sleep(nanoseconds: delayInMS * 1_000_000)
                    continue
                }
                throw StarcatMCPError.invalidArguments(message)
            }
            return  // 端口可用
        }
    }

    /// MCP 与决策 REST 共用同一组 Host/Origin，公布的 Bonjour 和 IP 都能直接调用。
    private func makeOriginValidator(
        port: Int,
        remoteHosts: [String] = []
    ) -> OriginValidator {
        let allowedHosts = (["127.0.0.1", "localhost", "[::1]"] + remoteHosts).map { "\($0):\(port)" }
        return OriginValidator(allowedHosts: allowedHosts, allowedOrigins: allowedHosts.map { "http://\($0)" })
    }

    private func validate(_ request: StarcatHTTPServerRequest) -> StarcatHTTPServerError? {
        guard request.path == "/mcp" || request.path == "/v1/systemone" else { return .notFound }
        guard settings.mcpServiceEnabled else { return .forbidden(StarcatMCPError.disabled.localizedDescription) }
        guard entitlementGate.isProUser else { return .forbidden(StarcatMCPError.requiresPro.localizedDescription) }
        guard let authorization = request.header("Authorization"), authorization.hasPrefix("Bearer ") else {
            return .unauthorized
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard token == bearerToken || deviceStore.isAuthorized(token: token) else { return .unauthorized }
        return nil
    }

    /// `POST /v1/systemone` 兼容 Jev SDK 的决策入口。
    ///
    /// 安全边界刻意沿用 MCP listener：服务开关、Pro、Bearer、Host/Origin 和
    /// `write` 权限完全一致。这里是传输层，不重新实现引擎选择或兜底。
    private func handlePublicRoute(
        _ request: StarcatHTTPServerRequest,
        originValidator: OriginValidator
    ) async -> StarcatHTTPServerRouteResponse? {
        guard request.path == "/v1/systemone" else { return nil }
        guard request.method.uppercased() == "POST" else {
            return Self.decisionResponse(statusCode: 400, message: "POST required")
        }
        do {
            let httpRequest = HTTPRequest(
                method: request.method,
                headers: request.headers,
                body: request.body,
                path: request.path
            )
            let context = HTTPValidationContext(httpMethod: request.method)
            if let rejected = originValidator.validate(httpRequest, context: context) {
                return Self.decisionResponse(
                    statusCode: rejected.statusCode,
                    message: rejected.statusCode == 421 ? "Host header not allowed" : "Origin not allowed"
                )
            }
            try StarcatMCPAccess.requireWrite(settings)
            if let encoding = request.header("Content-Encoding"), encoding.lowercased() != "identity" {
                return Self.decisionResponse(statusCode: 415, message: "Send an uncompressed System One request.")
            }
            let contentType = request.header("Content-Type") ?? ""
            let input: DecisionSystemOneInput
            if contentType.lowercased().hasPrefix("multipart/form-data") {
                input = try DecisionSystemOneInput.normalize(
                    multipartBody: request.body,
                    contentType: request.header("Content-Type")
                )
            } else {
                guard contentType.lowercased().hasPrefix("application/json") else {
                    throw DecisionInputError("headers.Content-Type: expected application/json or multipart/form-data")
                }
                input = try JSONDecoder().decode(DecisionSystemOneInput.self, from: request.body)
            }
            try requireImageHeader(for: input, request: request)
            guard let decisionSystemOneService else {
                throw StarcatMCPError.unsupported("Decision services are unavailable.")
            }
            let response = try await decisionSystemOneService.evaluate(input)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return StarcatHTTPServerRouteResponse(statusCode: 200, body: try encoder.encode(response))
        } catch let error as DecisionInputError {
            return Self.decisionResponse(statusCode: 400, message: error.localizedDescription)
        } catch is DecodingError {
            return Self.decisionResponse(statusCode: 400, message: "Invalid JSON request body")
        } catch StarcatMCPError.disabled {
            return Self.decisionResponse(statusCode: 403, message: StarcatMCPError.disabled.localizedDescription)
        } catch StarcatMCPError.requiresPro {
            return Self.decisionResponse(statusCode: 403, message: StarcatMCPError.requiresPro.localizedDescription)
        } catch let error as StarcatPublicCapabilityError {
            return Self.decisionResponse(statusCode: 403, message: error.localizedDescription)
        } catch DecisionEngineError.engineUnavailable(_, let reason) {
            return Self.decisionResponse(statusCode: 503, message: reason)
        } catch DecisionEngineError.engineNotRegistered {
            return Self.decisionResponse(statusCode: 400, message: "Decision engine is not registered")
        } catch DecisionEngineError.invalidAnswer, TypeSafeClientError.invalidAnswer {
            return Self.decisionResponse(statusCode: 502, message: "Decision engine returned an invalid answer")
        } catch let error as StarcatMCPError {
            return Self.decisionResponse(statusCode: 400, message: error.localizedDescription)
        } catch {
            return Self.decisionResponse(statusCode: 503, message: error.localizedDescription)
        }
    }

    private func requireImageHeader(for input: DecisionSystemOneInput, request: StarcatHTTPServerRequest) throws {
        let usesImages = input.assets?.isEmpty == false
            || input.questions.values.contains { $0.type == .box }
        let enabled = request.header("TypeSafe-Danger-Zone-Images")?.lowercased() == "true"
        guard !usesImages || enabled else {
            throw DecisionInputError("TypeSafe-Danger-Zone-Images: must be true for images or box questions")
        }
    }

    private static func decisionResponse(statusCode: Int, message: String) -> StarcatHTTPServerRouteResponse {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": message], options: [.sortedKeys])) ?? Data()
        return StarcatHTTPServerRouteResponse(statusCode: statusCode, body: body)
    }

    /// 一次性配对需经过 `deviceStore` 的 App 内确认，再签发当前设备自己的 token。
    private func handlePairingRoute(_ request: StarcatHTTPServerRequest) async -> StarcatHTTPServerRouteResponse? {
        guard request.path == "/pairing/exchange" else { return nil }
        guard request.method.uppercased() == "POST" else {
            return Self.pairingResponse(statusCode: 400, message: "POST required")
        }
        do {
            let exchange = try JSONDecoder().decode(StarcatMCPPairingExchangeRequest.self, from: request.body)
            let result = try await deviceStore.exchange(exchange)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return StarcatHTTPServerRouteResponse(statusCode: 200, body: try encoder.encode(result))
        } catch {
            return Self.pairingResponse(statusCode: 403, message: error.localizedDescription)
        }
    }

    private static func pairingResponse(statusCode: Int, message: String) -> StarcatHTTPServerRouteResponse {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": message], options: [.sortedKeys])) ?? Data()
        return StarcatHTTPServerRouteResponse(statusCode: statusCode, body: body)
    }
}
