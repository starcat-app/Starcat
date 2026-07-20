//
//  StarcatMCPService.swift
//  Starcat
//
//  Starcat 本机 MCP Service 协调器。
//
//  生命周期由 Settings 与 AppDependencies 驱动：
//  - 用户开启后，只在 Pro 权益有效时监听 `127.0.0.1:{port}/mcp`；
//  - Bearer token 来自全局 Starcat Local API Key，设置页集中在「集成」管理；
//  - 每个 HTTP 请求都会重新检查开关 / Pro / token，防止订阅状态变化后旧连接继续放行。
//

import Foundation
import MCP
import Observation

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
    private var runtime: StarcatMCPRuntime?
    private var httpServer: StarcatMCPLoopbackHTTPServer?
    private var activeTLSIdentity: StarcatMCPTLSIdentity?
    private var activeRemoteConnections = false
    private var startupTask: Task<Void, Never>?
    private var lifecycleGeneration = 0

    private(set) var state: State = .stopped
    var bearerToken: String { localAPIKeyStore.apiKey }

    init(
        settings: AppSettings,
        entitlementGate: EntitlementGate,
        localAPIKeyStore: StarcatLocalAPIKeyStore = .shared,
        deviceStore: StarcatMCPDeviceStore,
        facade: StarcatMCPFacade,
        writeFacade: StarcatMCPWriteFacade,
        notificationService: ReleaseNotificationService? = nil
    ) {
        self.settings = settings
        self.entitlementGate = entitlementGate
        self.localAPIKeyStore = localAPIKeyStore
        self.deviceStore = deviceStore
        self.facade = facade
        self.writeFacade = writeFacade
        self.notificationService = notificationService
    }

    var endpointURL: String {
        if settings.mcpAllowRemoteConnections {
            return "https://\(ProcessInfo.processInfo.hostName):\(settings.mcpServicePort)/mcp"
        }
        return "http://127.0.0.1:\(settings.mcpServicePort)/mcp"
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

    /// 每次点击都创建新的五分钟 invitation，避免手工配对与 Agent 配对复用 secret。
    func createPairingAgentInstruction() throws -> String {
        MCPAgentSetupPrompt.pairAgent(invitationURI: try createPairingInvitationURI())
    }

    /// invitation 只用于兑换逐设备 token，不能直接调用 MCP。
    private func createPairingInvitationURI() throws -> String {
        guard case .running = state else {
            throw StarcatMCPError.disabled
        }
        return try deviceStore.createInvitation(
            endpoint: endpointURL,
            certificateFingerprint: activeTLSIdentity?.certificateFingerprint
        )
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
        let runtime = StarcatMCPRuntime(
            facade: facade,
            writeFacade: writeFacade,
            originValidator: makeOriginValidator(
                port: port,
                allowsRemoteConnections: allowsRemoteConnections
            )
        )

        startupTask = Task { @MainActor in
            do {
                // NWListener.cancel() 是异步的，重启场景下旧 listener 的 socket
                // 释放有延迟；这里重试最多 10 次（每次等 200ms，累计 2s），
                // 避免用户看到「端口占用」误报。
                try Task.checkCancellation()
                try await waitForPortAvailable(port: port)
                try Task.checkCancellation()

                try await runtime.start()
                // 只有用户显式开启可信网络后才读取/生成系统 TLS identity。默认 loopback
                // 路径完全不触碰系统 Keychain，避免启动期授权弹窗和测试 host hang。
                let tlsIdentity = settings.mcpAllowRemoteConnections
                    ? try await Task.detached(priority: .userInitiated) {
                        try StarcatMCPTLSIdentityStore().loadOrCreate()
                    }.value
                    : nil
                let httpServer = StarcatMCPLoopbackHTTPServer(
                    port: port,
                    runtime: runtime,
                    tlsIdentity: tlsIdentity?.identity,
                    requestValidator: { [weak self] request in
                        self?.validate(request)
                    },
                    routeHandler: { [weak self] request in
                        await self?.handlePairingRoute(request)
                    }
                )
                try httpServer.start()

                guard !Task.isCancelled, generation == self.lifecycleGeneration else {
                    httpServer.stop()
                    await runtime.shutdown()
                    return
                }

                self.runtime = runtime
                self.httpServer = httpServer
                self.activeTLSIdentity = tlsIdentity
                self.activeRemoteConnections = self.settings.mcpAllowRemoteConnections
                self.state = .running(port: port)
                AppLog.network.info("MCP Service started (remote=\(self.activeRemoteConnections, privacy: .public), port=\(port, privacy: .public))")
            } catch is CancellationError {
                await runtime.shutdown()
            } catch {
                await runtime.shutdown()
                guard generation == self.lifecycleGeneration else { return }
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
                        underlying: DiagnosticEvent.summarize(error),
                        context: ["port": String(port)]
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
        activeTLSIdentity = nil
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

    /// MCP SDK 自带 DNS rebinding 防护，默认只认识 localhost；可信网络 endpoint
    /// 使用当前 Mac 的 Bonjour hostname，必须把同一个 hostname 精确加入 Host/Origin
    /// allowlist。这里不使用通配 hostname，也不关闭校验，避免任意 Host 借 listener
    /// 访问本机 MCP 服务。
    private func makeOriginValidator(
        port: Int,
        allowsRemoteConnections: Bool
    ) -> OriginValidator {
        let loopbackHosts = [
            "127.0.0.1:\(port)",
            "localhost:\(port)",
            "[::1]:\(port)"
        ]
        let scheme = allowsRemoteConnections ? "https" : "http"
        var allowedHosts = loopbackHosts
        var allowedOrigins = loopbackHosts.map { "\(scheme)://\($0)" }

        if allowsRemoteConnections {
            let remoteHost = "\(ProcessInfo.processInfo.hostName):\(port)"
            allowedHosts.append(remoteHost)
            allowedOrigins.append("https://\(remoteHost)")
        }
        return OriginValidator(allowedHosts: allowedHosts, allowedOrigins: allowedOrigins)
    }

    private func validate(_ request: StarcatHTTPServerRequest) -> StarcatHTTPServerError? {
        guard request.path == "/mcp" else { return .notFound }
        guard settings.mcpServiceEnabled else { return .forbidden(StarcatMCPError.disabled.localizedDescription) }
        guard entitlementGate.isProUser else { return .forbidden(StarcatMCPError.requiresPro.localizedDescription) }
        guard let authorization = request.header("Authorization"), authorization.hasPrefix("Bearer ") else {
            return .unauthorized
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard token == bearerToken || deviceStore.isAuthorized(token: token) else { return .unauthorized }
        return nil
    }

    /// 一次性配对是 MCP listener 上唯一的非 MCP route。它不接受业务参数，也不读取用户数据；
    /// 成功响应只有当前设备自己的 token，且必须先经过 `deviceStore` 的 App 内确认。
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
