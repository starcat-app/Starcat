//
//  CombinedGithubOAuthService.swift
//  Starcat
//
//  2026-06-29：组合 Device Flow + Web Flow 两个 grant type 的 OAuth Service。
//
//  设计动机：
//  - `GithubOAuthServiceProtocol` 是单一 actor 实现的协议，但 Starcat 同时支持两种 grant type：
//    Device Flow（默认）+ Web Application Flow（PKCE，可选）
//  - 之前的 `GithubDeviceFlowService` 只实现 Device Flow；点 Web Flow 入口会抛
//    "Device Flow actor does not support Web Flow"（因为 actor stub 拒绝）
//  - 解决方案：做一个组合 actor，把 Device Flow 协议方法 delegate 给 device actor，
//    Web Flow 协议方法 delegate 给 web actor。对调用方（`AuthSession`）来说仍是
//    单一 protocol 入口，不需要改 AuthSession 的 6 个方法调用点。
//
//  关键约束：
//  - 两个子 actor 独立 Sendable，可跨 actor 边界安全引用
//  - 6 个 delegate 方法本身不持有状态（纯转发），无并发问题
//  - DEBUG 模式仍用 `MockGithubOAuthService`（已实现两套方法）；本组合 actor
//    是生产侧专用，避免 Mock 路径混入
//

import Foundation

/// 组合 Device Flow + Web Flow 两种 grant type 的 OAuth Service。
///
/// 内部两个子 actor：
/// - `device: GithubDeviceFlowService` — 负责 Device Flow（`beginDeviceFlow` / `awaitAccessToken` / `reset`）
/// - `web: GithubWebFlowService` — 负责 Web Flow（`beginWebFlow` / `exchangeCodeForToken` / `resetWebFlow`）
///
/// 调用方（`AuthSession`）通过 `GithubOAuthServiceProtocol` 统一访问，无需关心路由。
actor CombinedGithubOAuthService: GithubOAuthServiceProtocol {

    private let device: GithubDeviceFlowService
    private let web: GithubWebFlowService

    init(
        device: GithubDeviceFlowService = GithubDeviceFlowService(),
        web: GithubWebFlowService = GithubWebFlowService()
    ) {
        self.device = device
        self.web = web
    }

    // MARK: - Device Flow 协议（delegate 到 device actor）

    func beginDeviceFlow() async throws -> OAuthDeviceCodeInfo {
        try await device.beginDeviceFlow()
    }

    func awaitAccessToken() async throws -> String {
        try await device.awaitAccessToken()
    }

    func reset() async {
        await device.reset()
    }

    // MARK: - Web Flow 协议（delegate 到 web actor）

    func beginWebFlow() async throws -> WebFlowStartInfo {
        try await web.beginWebFlow()
    }

    func exchangeCodeForToken(code: String) async throws -> String {
        try await web.exchangeCodeForToken(code: code)
    }

    func resetWebFlow() async {
        await web.resetWebFlow()
    }
}
