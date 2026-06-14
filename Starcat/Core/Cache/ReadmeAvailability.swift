//
//  ReadmeAvailability.swift
//  Starcat
//
//  README "已知不存在"（404）的进程级会话缓存。
//
//  ────────────────────────────────────────────────────────────────────────────
//  设计意图（HOM-201 P0-2，2026-06-14）
//  ────────────────────────────────────────────────────────────────────────────
//
//  之前 `ReadmeViewModel` 用一个私有字段 `sessionNotFound: Set<Int64>` 记录
//  当前会话内已确认 404 的 repoId，让"重复点同一个无 README 的 repo"短路掉网络请求。
//  问题：manage / active 两条路径用的是**不同的 ReadmeViewModel 实例**——manage 是
//  HomeView 的全局单例，active 是每个 `ActivityDetailScaffoldShell` 各自 new 一个。
//  跨 VM 实例之间这个 Set **不共享**：
//    - manage 详情命中 404 之后切到 activity 详情看同一 repo，又会重新请求一次；
//    - activity Shell 重建（窗口切换 / 同分支切 item）后局部 VM 被丢，sessionNotFound
//      整个集合丢失，再选同一 repo 等价于冷启动。
//
//  本类是把这个集合提到 `AppDependencies` 单例的共享对象，让所有 VM 实例读写同一份
//  状态——跨场景查同一 repo 时只发一次网络请求。
//
//  ────────────────────────────────────────────────────────────────────────────
//  设计取舍
//  ────────────────────────────────────────────────────────────────────────────
//
//  - **@MainActor final class**：
//    ReadmeViewModel 已经在 @MainActor 上，访问无需 await，保持
//    `loadInternal` 入口"同步判 404 短路 → 同步设 state = .empty → return" 的原行为
//    （sessionNotFound 短路必须同步生效，不能让 .loading 闪一帧再变 .empty）。
//    如果改 actor，loadInternal 入口的同步路径会被打断。
//  - **仅 repoId 维度**：
//    trending 路径（`loadTrending`）按产品决策不设 404 短路（trending repo 切换频繁,
//    没必要在 session 内禁止重试），所以这里不暴露 fullName 维度的方法，避免误用。
//    要加 trending 短路时再单独扩 `markNotFound(fullName:)` 这组方法。
//  - **进程级、不持久化**：
//    与原 `sessionNotFound` 行为对齐——app 冷启动时清空，让作者可能补的 README 有一次
//    重新被发现的机会。本类不接 `DatabaseManaging`，没有 schema migration 风险。
//
//  ────────────────────────────────────────────────────────────────────────────
//  使用约束
//  ────────────────────────────────────────────────────────────────────────────
//
//  - 由 `AppDependencies` 持有唯一实例，通过 environment / 构造函数注入给所有
//    `ReadmeViewModel`。**不要在调用方 new 第二份**——会破坏跨 VM 共享语义。
//  - 写入时机：`ReadmeViewModel.loadInternal` 的 `.notFound` 分支（manage / active）。
//  - 读取时机：`ReadmeViewModel.loadInternal` 入口（forceRefresh=false 路径）。
//  - 清除时机：`ReadmeViewModel.loadInternal` 的 forceRefresh=true 路径，给用户的
//    手动刷新一次重试机会。
//

import Foundation

/// README "已知不存在" 状态的进程级共享缓存。
///
/// 详见文件头注释。
@MainActor
final class ReadmeAvailability {

    /// session 内已确认无 README（GitHub 404）的 repoId 集合。
    /// 命中 → 自动加载短路到 .empty 不再请求 GitHub。
    private var notFoundRepoIds: Set<Int64> = []

    init() {}

    /// 是否已知该 repo 没有 README。
    func isKnownNotFound(repoId: Int64) -> Bool {
        notFoundRepoIds.contains(repoId)
    }

    /// 标记该 repo 没有 README（refresh 收到 404 时调用）。
    func markNotFound(repoId: Int64) {
        notFoundRepoIds.insert(repoId)
    }

    /// 清掉该 repo 的"已知不存在"标记（用户手动 reload 时调用，给一次重试机会）。
    func clearNotFound(repoId: Int64) {
        notFoundRepoIds.remove(repoId)
    }
}
