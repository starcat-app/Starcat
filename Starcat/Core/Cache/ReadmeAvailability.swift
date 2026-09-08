//
//  ReadmeAvailability.swift
//  Starcat
//
//  README "已知不存在"（404）的进程级会话状态。
//
//  ────────────────────────────────────────────────────────────────────────────
//  设计意图（HOM-201 P0-2，2026-06-14；2026-09-09 修订）
//  ────────────────────────────────────────────────────────────────────────────
//
//  最初用途：在会话内记住 GitHub 已确认 404 的 repoId，让「重复点同一个无 README
//  的 repo」短路掉网络请求；并提到 `AppDependencies` 单例，让 manage / active 等多
//  个 `ReadmeViewModel` 共享同一份集合。
//
//  产品修订（2026-09-09，dong4j）：作者可能随后补上 README。自动 `load` **不再**
//  因「已知 404」短路——每次重新选中无 HTML 的仓都必须打 GitHub。本类仍保留写入 /
//  查询 API，供调试或其它读者使用，但 `ReadmeViewModel.loadInternal` 入口已不再
//  根据 `isKnownNotFound` early-return。
//
//  ────────────────────────────────────────────────────────────────────────────
//  设计取舍
//  ────────────────────────────────────────────────────────────────────────────
//
//  - **@MainActor final class**：与 `ReadmeViewModel` 同隔离域，访问无需 await。
//  - **仅 repoId 维度**：trending 路径本来就不做 404 短路，这里不暴露 fullName API。
//  - **进程级、不持久化**：冷启动清空；不接 DB，无 schema 风险。
//
//  ────────────────────────────────────────────────────────────────────────────
//  使用约束
//  ────────────────────────────────────────────────────────────────────────────
//
//  - 由 `AppDependencies` 持有唯一实例注入各 `ReadmeViewModel`。不要 new 第二份。
//  - 写入：`loadInternal` 的 `.notFound` 分支。
//  - 清除：每次 `loadInternal` 入口（避免留下会误导其它读者的过期标记）。
//

import Foundation

/// README "已知不存在" 状态的进程级共享集合（不再用于自动 load 短路）。
///
/// 详见文件头注释。
@MainActor
final class ReadmeAvailability {

    /// session 内曾确认无 README（GitHub 404）的 repoId 集合。
    private var notFoundRepoIds: Set<Int64> = []

    init() {}

    /// 是否已知该 repo 没有 README（查询用；自动 load 不再据此短路）。
    func isKnownNotFound(repoId: Int64) -> Bool {
        notFoundRepoIds.contains(repoId)
    }

    /// 标记该 repo 没有 README（refresh 收到 404 时调用）。
    func markNotFound(repoId: Int64) {
        notFoundRepoIds.insert(repoId)
    }

    /// 清掉该 repo 的"已知不存在"标记。
    func clearNotFound(repoId: Int64) {
        notFoundRepoIds.remove(repoId)
    }
}
