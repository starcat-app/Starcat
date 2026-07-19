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
    private let facade: StarcatMCPFacade
    private let writeFacade: StarcatMCPWriteFacade
    private let notificationService: ReleaseNotificationService?
    private var runtime: StarcatMCPRuntime?
    private var httpServer: StarcatMCPLoopbackHTTPServer?
    private var startupTask: Task<Void, Never>?
    private var lifecycleGeneration = 0

    private(set) var state: State = .stopped
    var bearerToken: String { localAPIKeyStore.apiKey }

    init(
        settings: AppSettings,
        entitlementGate: EntitlementGate,
        localAPIKeyStore: StarcatLocalAPIKeyStore = .shared,
        facade: StarcatMCPFacade,
        writeFacade: StarcatMCPWriteFacade,
        notificationService: ReleaseNotificationService? = nil
    ) {
        self.settings = settings
        self.entitlementGate = entitlementGate
        self.localAPIKeyStore = localAPIKeyStore
        self.facade = facade
        self.writeFacade = writeFacade
        self.notificationService = notificationService
    }

    var endpointURL: String {
        "http://127.0.0.1:\(settings.mcpServicePort)/mcp"
    }

    var clientConfigSnippet: String {
        """
        {
          "mcpServers": {
            "starcat": {
              "type": "http",
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

        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        let runtime = StarcatMCPRuntime(facade: facade, writeFacade: writeFacade)

        startupTask = Task { @MainActor in
            do {
                // NWListener.cancel() 是异步的，重启场景下旧 listener 的 socket
                // 释放有延迟；这里重试最多 10 次（每次等 200ms，累计 2s），
                // 避免用户看到「端口占用」误报。
                try Task.checkCancellation()
                try await waitForPortAvailable(port: port)
                try Task.checkCancellation()

                try await runtime.start()
                let httpServer = StarcatMCPLoopbackHTTPServer(
                    port: port,
                    runtime: runtime,
                    requestValidator: { [weak self] request in
                        self?.validate(request)
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
                self.state = .running(port: port)
                AppLog.network.info("MCP Service started on 127.0.0.1:\(port, privacy: .public)")
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
        startupTask?.cancel()
        startupTask = nil
        httpServer?.stop()
        httpServer = nil
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

    private func validate(_ request: StarcatHTTPServerRequest) -> StarcatHTTPServerError? {
        guard request.path == "/mcp" else { return .notFound }
        guard settings.mcpServiceEnabled else { return .forbidden(StarcatMCPError.disabled.localizedDescription) }
        guard entitlementGate.isProUser else { return .forbidden(StarcatMCPError.requiresPro.localizedDescription) }
        guard request.header("Authorization") == "Bearer \(bearerToken)" else { return .unauthorized }
        return nil
    }
}
