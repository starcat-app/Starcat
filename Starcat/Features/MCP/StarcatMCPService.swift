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
        writeFacade: StarcatMCPWriteFacade
    ) {
        self.settings = settings
        self.entitlementGate = entitlementGate
        self.tokenStore = tokenStore
        self.facade = facade
        self.writeFacade = writeFacade
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
        if settings.mcpServiceEnabled, entitlementGate.isProUser {
            start()
        } else {
            stop()
        }
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
                await registry.register(on: server)
                try await server.start(transport: transport)
                let httpServer = StarcatMCPLoopbackHTTPServer(
                    port: settings.mcpServicePort,
                    transport: transport,
                    requestValidator: { [weak self] request in
                        self?.validate(request)
                    }
                )
                try httpServer.start()
                self.server = server
                self.transport = transport
                self.httpServer = httpServer
                self.state = .running(port: self.settings.mcpServicePort)
                AppLog.network.info("MCP Service started on 127.0.0.1:\(self.settings.mcpServicePort, privacy: .public)")
            } catch {
                await transport.disconnect()
                self.state = .failed(error.localizedDescription)
                AppLog.network.error("MCP Service failed: \(error.localizedDescription, privacy: .public)")
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
