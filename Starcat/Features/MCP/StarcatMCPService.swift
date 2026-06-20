//
//  StarcatMCPService.swift
//  Starcat
//
//  Starcat 本机 MCP Service 协调器。
//
//  生命周期由 Settings 与 AppDependencies 驱动：
//  - 用户开启后，只在 Pro 权益有效时监听 `127.0.0.1:{port}/mcp`；
//  - Bearer token 存在本地加密凭据文件，设置页只展示给用户复制；
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
    private let tokenStore: StarcatMCPTokenStore
    private let facade: StarcatMCPFacade
    private let writeFacade: StarcatMCPWriteFacade
    private let notificationService: ReleaseNotificationService?
    private var server: Server?
    private var transport: StatelessHTTPServerTransport?
    private var httpServer: StarcatMCPLoopbackHTTPServer?

    private(set) var state: State = .stopped
    private(set) var bearerToken: String

    init(
        settings: AppSettings,
        entitlementGate: EntitlementGate,
        tokenStore: StarcatMCPTokenStore = StarcatMCPTokenStore(),
        facade: StarcatMCPFacade,
        writeFacade: StarcatMCPWriteFacade,
        notificationService: ReleaseNotificationService? = nil
    ) {
        self.settings = settings
        self.entitlementGate = entitlementGate
        self.tokenStore = tokenStore
        self.facade = facade
        self.writeFacade = writeFacade
        self.notificationService = notificationService
        self.bearerToken = tokenStore.loadOrCreateToken()
    }

    var endpointURL: String {
        "http://127.0.0.1:\(settings.mcpServicePort)/mcp"
    }

    var clientConfigSnippet: String {
        """
        {
          "mcpServers": {
            "starcat": {
              "url": "\(endpointURL)",
              "headers": {
                "Authorization": "Bearer \(bearerToken)"
              }
            }
          }
        }
        """
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
        if case .running(let currentPort) = state, currentPort == settings.mcpServicePort {
            return
        }
        stop()

        let port = settings.mcpServicePort

        // 端口范围校验同步做（纯数学检查，不需要等旧 listener 释放）
        guard (1024...65_535).contains(port) else {
            state = .failed(String(format: String.l10n("settings.mcp.port.error.invalidFormat"), port))
            return
        }

        let transport = StatelessHTTPServerTransport()
        let server = Server(
            name: "starcat",
            version: "0.1.0",
            title: "Starcat",
            instructions: "Expose Starcat starred repository context to local agents. Write tools are Pro-only, local-data-only, settings-gated, and audited.",
            capabilities: .init(
                resources: .init(listChanged: false),
                tools: .init(listChanged: false)
            )
        )
        let registry = StarcatMCPToolRegistry(facade: facade, writeFacade: writeFacade)

        Task { @MainActor in
            do {
                // NWListener.cancel() 是异步的，重启场景下旧 listener 的 socket
                // 释放有延迟；这里重试最多 5 次（每次等 200ms，累计 1s），
                // 避免用户看到「端口占用」误报。
                try await waitForPortAvailable(port: port)

                await registry.register(on: server)
                try await server.start(transport: transport)
                let httpServer = StarcatMCPLoopbackHTTPServer(
                    port: port,
                    transport: transport,
                    requestValidator: { [weak self] request in
                        self?.validate(request)
                    }
                )
                try httpServer.start()
                self.server = server
                self.transport = transport
                self.httpServer = httpServer
                self.state = .running(port: port)
                AppLog.network.info("MCP Service started on 127.0.0.1:\(port, privacy: .public)")
            } catch {
                await transport.disconnect()
                self.state = .failed(error.localizedDescription)
                AppLog.network.error("MCP Service failed: \(error.localizedDescription, privacy: .public)")
                await self.notificationService?.dispatchMCPFailure(message: error.localizedDescription)
            }
        }
    }

    func stop() {
        httpServer?.stop()
        httpServer = nil
        let transport = transport
        self.transport = nil
        self.server = nil
        if transport != nil {
            Task {
                await transport?.disconnect()
            }
        }
        state = .stopped
    }

    /// 端口可用性预检，带重试。
    ///
    /// `NWListener.cancel()` 是异步操作，重启场景下旧 listener 的 socket 释放
    /// 有延迟（通常 < 50ms）。这里用 POSIX `bind` 做同步探测，连续失败则等 200ms
    /// 重试，最多 5 次（累计 1s）。真正被其他进程占用时，5 次后仍会正确报错。
    private func waitForPortAvailable(
        port: Int,
        maxRetries: Int = 5,
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

    func rotateToken() {
        bearerToken = tokenStore.rotateToken()
        if case .running = state {
            stop()
            start()
        }
    }

    private func validate(_ request: StarcatHTTPServerRequest) -> StarcatHTTPServerError? {
        guard request.path == "/mcp" else { return .notFound }
        guard settings.mcpServiceEnabled else { return .forbidden(StarcatMCPError.disabled.localizedDescription) }
        guard entitlementGate.isProUser else { return .forbidden(StarcatMCPError.requiresPro.localizedDescription) }
        guard request.header("Authorization") == "Bearer \(bearerToken)" else { return .unauthorized }
        return nil
    }
}
