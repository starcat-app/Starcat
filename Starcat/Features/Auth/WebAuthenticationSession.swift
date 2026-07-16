//
//  WebAuthenticationSession.swift
//  Starcat
//
//  GitHub Web Flow 的系统认证窗口适配层。
//
//  该文件只负责把授权 URL 交给 ASWebAuthenticationSession，并把系统回调 URL
//  返回给 AuthSession。PKCE、state 校验、code 换 token 等 OAuth 规则仍由现有
//  GithubWebFlowService / AuthSession 负责，避免把业务状态机耦合进 AppKit 桥接层。
//

import AppKit
import AuthenticationServices
import Foundation

/// 系统认证窗口可能返回的有限错误集合。
///
/// 单独建模取消状态，是为了让 AuthSession 将用户主动关闭系统认证窗口视为正常取消，
/// 不在登录页展示红色错误提示。
enum WebAuthenticationSessionError: LocalizedError, Equatable, Sendable {
    case cancelled
    case failed(message: String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Authentication was cancelled."
        case .failed(let message):
            return message
        }
    }
}

/// Web 认证窗口抽象，允许 AuthSession 单测在不弹真实系统窗口的情况下驱动回调。
@MainActor
protocol WebAuthenticationSessionProviding: AnyObject {
    /// 展示授权页面，并在认证结束时返回自定义 URL Scheme 回调。
    func start(
        authorizationURL: URL,
        callbackURLScheme: String,
        completion: @escaping @MainActor @Sendable (Result<URL, WebAuthenticationSessionError>) -> Void
    ) throws

    /// 关闭当前认证窗口。没有进行中的会话时为 no-op。
    func cancel()
}

/// 使用 `ASWebAuthenticationSession` 展示 GitHub Web Flow。
///
/// 生命周期约束：实例由 AuthSession 长期持有，但 NSWindow 和系统 session 只在一次认证
/// 期间持有；结束或取消后立即释放，避免引入额外全局窗口或改变 Starcat 的窗口模型。
@MainActor
final class SystemWebAuthenticationSession: NSObject, WebAuthenticationSessionProviding,
    ASWebAuthenticationPresentationContextProviding
{
    typealias Completion = @MainActor @Sendable (
        Result<URL, WebAuthenticationSessionError>
    ) -> Void

    private var session: ASWebAuthenticationSession?
    private var presentationWindow: NSWindow?
    private var completion: Completion?

    func start(
        authorizationURL: URL,
        callbackURLScheme: String,
        completion: @escaping Completion
    ) throws {
        guard session == nil else {
            throw WebAuthenticationSessionError.failed(
                message: "A web authentication session is already in progress."
            )
        }

        // ASWebAuthenticationSession 必须依附用户当前可见窗口。这里不创建兜底窗口，
        // 因为 Web Flow 只能从登录 sheet 的用户点击触发，正常情况下必然存在主窗口。
        guard let window = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible })
        else {
            throw WebAuthenticationSessionError.failed(
                message: "Unable to present the GitHub sign-in window."
            )
        }

        self.presentationWindow = window
        self.completion = completion

        let session = ASWebAuthenticationSession(
            url: authorizationURL,
            callback: .customScheme(callbackURLScheme),
            completionHandler: Self.makeSystemCallback { [weak self] result in
                self?.finish(with: result)
            }
        )
        session.presentationContextProvider = self
        // 保留 GitHub 的系统浏览器 Cookie，用户已有会话时无需重复输入账号密码。
        session.prefersEphemeralWebBrowserSession = false

        self.session = session
        guard session.start() else {
            cleanup()
            throw WebAuthenticationSessionError.failed(
                message: "Unable to start the GitHub sign-in session."
            )
        }
    }

    func cancel() {
        session?.cancel()
        // cancelWebFlow 已同步重置 AuthSession；这里清掉 completion，避免系统稍后返回
        // canceledLogin 时重复推进一次状态机。
        cleanup()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let presentationWindow else {
            preconditionFailure("ASWebAuthenticationSession requested an anchor after cleanup")
        }
        return presentationWindow
    }

    private func finish(with result: Result<URL, WebAuthenticationSessionError>) {
        guard let completion else {
            cleanup()
            return
        }
        cleanup()
        completion(result)
    }

    private func cleanup() {
        session = nil
        presentationWindow = nil
        completion = nil
    }

    /// 创建 AuthenticationServices 可以从任意 XPC / dispatch 队列调用的原始 callback。
    ///
    /// 不能在 `start()` 的 `@MainActor` 上下文中直接写 closure literal：Swift 6 会让
    /// closure 继承 MainActor 隔离，而 ASWebAuthenticationSession 实际可能从后台 XPC
    /// 队列回调，闭包尚未执行就会在 `swift_task_checkIsolated` 触发
    /// `_dispatch_assert_queue_fail`。把 closure 放进 nonisolated 工厂创建后，原始入口
    /// 不再要求主队列；只有状态清理与 AuthSession 推进显式切回 MainActor。
    nonisolated static func makeSystemCallback(
        completion: @escaping Completion
    ) -> @Sendable (URL?, (any Error)?) -> Void {
        { callbackURL, error in
            let result = makeResult(callbackURL: callbackURL, error: error)
            Task { @MainActor in
                completion(result)
            }
        }
    }

    nonisolated private static func makeResult(
        callbackURL: URL?,
        error: (any Error)?
    ) -> Result<URL, WebAuthenticationSessionError> {
        if let callbackURL {
            return .success(callbackURL)
        }

        if let authenticationError = error as? ASWebAuthenticationSessionError,
           authenticationError.code == .canceledLogin {
            return .failure(.cancelled)
        }

        return .failure(
            .failed(message: error?.localizedDescription ?? "GitHub sign-in did not return a callback URL.")
        )
    }
}
