//
//  ReadmeInflightTracker.swift
//  Starcat
//
//  README 网络刷新的 in-flight 请求去重器（HOM-201 P0-3，2026-06-14）。
//
//  ────────────────────────────────────────────────────────────────────────────
//  问题
//  ────────────────────────────────────────────────────────────────────────────
//
//  P0-2 把 `sessionNotFound` 提到了 `ReadmeAvailability` 单例，跨 VM 实例共享，
//  但 ReadmeAPI 的实际网络刷新调用还是 VM 各自发起。`ReadmeAPI` 持有的 client
//  / repository 都是 process-wide 共享，但每次 `refreshReadme(for:)` /
//  `refreshTrendingReadme(owner:repo:)` 进来都会原地发起一次 If-None-Match 请求,
//  没有"同一 repo 已经在刷"的合并机制。在以下场景会产生重复请求：
//
//  1. manage 详情切到 active 详情时,manage 全局 VM 的旧 refresh 任务可能未完成,
//     active Shell 局部 VM 又发起同一 `repo.id` 的 refresh。
//  2. 用户在 manage 列表 hover 多个 row 触发 prefetch（P1-1 后），同一 repo
//     被点击进入详情时又走 refresh。
//  3. weekly / trending 路径上同一 `owner/repo` 被两个 ContentView 同时显示
//     的极端情况。
//
//  GitHub 匿名请求是 60/h，登录后 5000/h——多刷一次都是浪费。
//
//  ────────────────────────────────────────────────────────────────────────────
//  方案
//  ────────────────────────────────────────────────────────────────────────────
//
//  - **actor 单例**：actor 保证字典读写原子，且让 Sendable 边界落在 actor 调用上。
//  - **两份字典**：manage（PK = repoId Int64）和 trending（PK = fullName String），
//    与 `ReadmeAPI` 的两条路径一一对应。
//  - **dedupe 接口**：调用方传业务 closure，actor 内部检查是否已有 in-flight：
//    - 命中 → 返回已有 `Task` 的 value（实质 await 完成态）。
//    - 未命中 → spawn 新 `Task` 运行 closure，登记到字典；完成后自清。
//
//  为何字典 value 是 `Task<ReadmeRefreshResult, Never>`：
//  - `ReadmeAPI.refreshReadme(for:)` / `refreshTrendingReadme(...)` 把所有错误
//    包到 `.failed(error)` 不 throw（SWR 模式），所以 Task 失败通道是 `Never`。
//  - Task value 类型是 `ReadmeRefreshResult`，已被声明为 `@unchecked Sendable`
//    （`.failed(any Error)` 让自动推导失败，但 Error 实例在我们代码里实际都是
//    NetworkError / GRDB error 这些不可变值类型，跨线程读取安全——只是协议层
//    没标 Sendable）。
//
//  ────────────────────────────────────────────────────────────────────────────
//  使用约束
//  ────────────────────────────────────────────────────────────────────────────
//
//  - 由 `AppDependencies` 持有唯一实例，**仅供 `ReadmeAPI` 内部消费**；ViewModel
//    层不直接调本类，调用入口仍是 `ReadmeAPI.refreshReadme` / `refreshTrendingReadme`。
//  - dedupe 不区分调用方的 `forceRefresh` 与否——`refreshReadme` 本身就总是带
//    `If-None-Match` 做条件请求，A / B 期望的结果完全一致，复用安全。
//  - 不持久化、不跨进程；只解决"同一进程内并发重复请求"。
//

import Foundation

/// `ReadmeAPI` 网络刷新的 in-flight 请求去重器。详见文件头注释。
actor ReadmeInflightTracker {

    /// manage 路径（PK = `repo.id`）的在飞 Task 表。
    private var manageInflight: [Int64: Task<ReadmeRefreshResult, Never>] = [:]

    /// trending 路径（PK = `owner/repo`）的在飞 Task 表。
    private var trendingInflight: [String: Task<ReadmeRefreshResult, Never>] = [:]

    init() {}

    /// 对 manage 路径（按 `repoId`）做请求去重。
    ///
    /// - 已有 in-flight Task：直接 `await` 它的 value，与首发请求拿到同一结果。
    /// - 无 in-flight：spawn 新 Task 执行 `operation`，登记到字典；Task 完成后
    ///   回到 actor 上下文把自己从字典清掉，避免 stale Task 误命中。
    func dedupeManage(
        repoId: Int64,
        operation: @escaping @Sendable () async -> ReadmeRefreshResult
    ) async -> ReadmeRefreshResult {
        if let existing = manageInflight[repoId] {
            return await existing.value
        }

        let task = Task<ReadmeRefreshResult, Never> { [weak self] in
            let result = await operation()
            // 回到 actor 串行域清字典，避免 Task 已完成但条目还在导致下一次调用命中 stale Task
            await self?.clearManage(repoId: repoId)
            return result
        }
        manageInflight[repoId] = task
        return await task.value
    }

    /// 对 trending 路径（按 `owner/repo`）做请求去重。语义与 `dedupeManage` 完全对齐。
    func dedupeTrending(
        fullName: String,
        operation: @escaping @Sendable () async -> ReadmeRefreshResult
    ) async -> ReadmeRefreshResult {
        if let existing = trendingInflight[fullName] {
            return await existing.value
        }

        let task = Task<ReadmeRefreshResult, Never> { [weak self] in
            let result = await operation()
            await self?.clearTrending(fullName: fullName)
            return result
        }
        trendingInflight[fullName] = task
        return await task.value
    }

    // MARK: - Private

    private func clearManage(repoId: Int64) {
        manageInflight[repoId] = nil
    }

    private func clearTrending(fullName: String) {
        trendingInflight[fullName] = nil
    }
}
