//
//  GitHubAuthRedirectDelegate.swift
//  Starcat
//
//  `URLSessionTaskDelegate`：处理 GitHub REST API 的 HTTP 重定向，
//  避免 301 重定向后丢失 `Authorization` header 导致 401 误判 → 自动登出。
//
//  ─────────────────────────────────────────────────────────────────────────────
//  D-25 背景（2026-06-11 dong4j 真机复现：运行过程中频繁被自动退出登录）
//  ─────────────────────────────────────────────────────────────────────────────
//
//  ## 症状
//  用户在 Weekly / Activity 详情页浏览时，App 突然跳回登录页。Console.app 日志：
//      Session invalidated (401/unauthorized in use); clearing token
//  当天连续触发 4 次，每次都在用户切换 weekly 详情时秒级发生。
//
//  ## 根因（CFNetwork + AuthSession 日志拼出的完整链路）
//  - `WeeklyDetailView.resolveRepo` 调 `apiClient.repo(owner:repo:)` →
//    `GET https://api.github.com/repos/{owner}/{name}` + `Authorization: Bearer <token>`
//  - 目标 repo 已经被 GitHub 改名 / 转移 → 服务端返回 `301 Moved Permanently` +
//    `Location: https://api.github.com/repositories/{numeric-id}`
//  - `URLSession.shared`（含一切**没挂 delegate** 的 URLSession）默认 follow 重定向
//    时**会丢弃原请求的 `Authorization` header**。这是 URLSession 的安全策略：
//    防止把 token 跨域泄漏给非预期主机
//  - 重定向后的请求**匿名访问** `/repositories/{id}` —— 此时若 GitHub 匿名 60次/小时
//    配额已耗尽（或服务端策略性返回鉴权要求），返回 **401 Unauthorized**
//  - `GitHubAPIClient.perform()` 把 401 一律映射成"token 失效"→ 触发集中式
//    `onUnauthorized` 回调 → `AuthSession.invalidateSession()` 删 token + 切
//    `.unauthenticated` → 用户被自动登出
//
//  CFNetwork 日志可复读（PID 94742 / 18:57:33）：
//    18:57:33.396  Task <B8427730>.<42> received response, status 301
//    18:57:33.697  Task <B8427730>.<42> received response, status 401
//    18:57:33.698  Session invalidated (401/unauthorized in use); clearing token
//
//  ─────────────────────────────────────────────────────────────────────────────
//  ## 修复设计
//  ─────────────────────────────────────────────────────────────────────────────
//
//  - 实现 `urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`
//    （URLSessionTaskDelegate 协议），接管重定向决策
//  - **仅当**重定向后的 URL 与原 URL **同 host** 时，把原请求的 `Authorization`
//    header 重新加到新请求上；其他自定义 header（User-Agent / Accept /
//    X-GitHub-Api-Version）URLSession 默认会保留，不需要手动重设
//  - 跨域重定向（例如重定向到 `raw.githubusercontent.com` / 第三方）保持
//    URLSession 默认行为（丢失 Authorization），符合 URLSession 安全模型
//  - 如果原请求本来就没带 `Authorization`（匿名 API 调用），无需透传
//
//  ─────────────────────────────────────────────────────────────────────────────
//  ## 关键约束（避坑提醒）
//  ─────────────────────────────────────────────────────────────────────────────
//
//  - delegate 必须由 URLSession **强引用**。`URLSession.init(configuration:delegate:delegateQueue:)`
//    会自动 retain delegate，所以只要 URLSession 还存活就 OK。**不要**在生产侧
//    把 delegate 当作临时变量丢弃
//  - URLSession delegate 回调发生在内部私有队列（非主线程，非 actor 隔离）。
//    本类**无任何可变状态**（stateless），所以 `@unchecked Sendable` 安全
//  - `URLSession.shared` **不能**用此 delegate—— `.shared` 是单例不接受 delegate。
//    生产侧改用 `URLSession(configuration:.default, delegate: this, delegateQueue: nil)`
//  - 同域判定用 `URL.host`（不带端口、忽略大小写比较）；GitHub API 全部走
//    `api.github.com`，所以实际触发的就是 api.github.com → api.github.com 链路
//

import Foundation

/// 让 GitHub REST API 的 301/302 重定向**保留同域 Authorization** 的 URLSession delegate。
///
/// 用法：装 `GitHubAPIClient` 默认 session 时绑定一份实例：
/// ```swift
/// let session = URLSession(
///     configuration: .default,
///     delegate: GitHubAuthRedirectDelegate(),
///     delegateQueue: nil
/// )
/// ```
final class GitHubAuthRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    /// 重定向回调。返回的 `URLRequest?` 决定 URLSession follow 哪个 request：
    /// - 传 `nil` → 拒绝重定向，原 task 收到 3xx 响应
    /// - 传 modified `URLRequest` → URLSession 用新 request 继续 follow
    /// - 传未修改的 `request` → URLSession 用 SDK 默认构造的新 request（**已丢
    ///   Authorization**）继续 follow
    ///
    /// 本实现仅在"同域 + 原请求带 Authorization"时把 Authorization 透传到新 request。
    /// 其它情况（跨域 / 原请求匿名）走 SDK 默认行为。
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let originalHost = task.originalRequest?.url?.host?.lowercased()
        let redirectedHost = request.url?.host?.lowercased()

        // 跨域：保持 SDK 默认（丢 Authorization）
        guard let originalHost,
              let redirectedHost,
              originalHost == redirectedHost else {
            completionHandler(request)
            return
        }

        // 原请求本来就匿名：无需透传
        guard let authorization = task.originalRequest?.value(forHTTPHeaderField: "Authorization"),
              !authorization.isEmpty else {
            completionHandler(request)
            return
        }

        // 同域 + 原请求已鉴权：把 Authorization 加回新 request
        var newRequest = request
        newRequest.setValue(authorization, forHTTPHeaderField: "Authorization")
        completionHandler(newRequest)
    }
}
