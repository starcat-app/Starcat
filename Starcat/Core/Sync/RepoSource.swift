//
//  RepoSource.swift
//  Starcat
//
//  R-01 详情页 Repo 解析的「源」抽象（v1.2 dong4j review R3：Chain of Responsibility）。
//
//  ────────────────────────────────────────────────────────────────────────────
//  设计意图（详细设计 §5.2）
//  ────────────────────────────────────────────────────────────────────────────
//
//  详情页打开时，需要尽可能拿到完整的 `Repo` 对象（决定显示哪些 section）。
//  来源优先级（chain 顺序）：
//
//    1. LocalRepoSource          —— 本地 SQLite（已 star 的最全字段）
//    2. BackendHintRepoSource    —— 列表传过来的 backend hint DTO（零网络 IO，最快）
//    3. BackendAggregateRepoSource —— 后端单 repo 聚合接口（R-01 内占位永远 nil）
//    4. GitHubFallbackRepoSource —— GitHub `/repos/{o}/{r}` 兜底
//    5. MinimalRepoSource        —— 永远命中（用 hint / owner-name 拼最小 Repo）
//
//  采纳 Chain of Responsibility 而非「Resolver 单方法 if-else」是为了：
//  - 加新源（如 Memory Cache / Sharing API / CloudKit Sync）只 conform 协议、
//    不改 Resolver 主体（避免 god object）
//  - 测试每个 source 独立（输入 owner/name/hint → 输出 Repo?）
//  - 链顺序可在 `AppDependencies` 装配时调整（不同环境 / 不同测试不同 chain）
//  - 日志统一（命中是哪个 source 走 `AppLog.sync.info`）
//
//  ────────────────────────────────────────────────────────────────────────────
//  契约
//  ────────────────────────────────────────────────────────────────────────────
//
//  - 命中：返回 `Repo`，链停止询问
//  - 未命中（不抛错的「我不知道」）：返回 `nil`，链继续询问下一个
//  - throws：链 catch 并跳过此源继续询问下一个；不让单源故障击穿整条链
//

import Foundation

/// 详情页 Repo 解析的「源」抽象。
///
/// 一个 source 表示「我可以从某个地方拿到 Repo 对象」。`RepoResolver` 持有
/// `[any RepoSource]` 数组，按顺序询问每一个，命中即返回。
protocol RepoSource: Sendable {

    /// 用于日志 / 可观测性（命中时打 `AppLog.sync.info`）。
    var name: String { get }

    /// 尝试从此源解析 repo。
    /// - parameter owner: 仓库 owner login
    /// - parameter name: 仓库 name（不含 owner 前缀）
    /// - parameter hint: 列表场景传过来的 backend DTO；可能为 nil
    /// - returns: 命中返回 `Repo`；未命中返回 `nil`（链继续询问下一个）
    /// - throws: IO 错误。链会 catch 并跳过此源继续询问下一个
    func tryResolve(owner: String, name: String, hint: StarcatRepoCardDTO?) async throws -> Repo?
}
