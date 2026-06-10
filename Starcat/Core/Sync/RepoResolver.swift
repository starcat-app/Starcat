//
//  RepoResolver.swift
//  Starcat
//
//  R-01 详情页 Repo 解析链（Chain of Responsibility 协调器）。
//
//  ────────────────────────────────────────────────────────────────────────────
//  职责
//  ────────────────────────────────────────────────────────────────────────────
//
//  - 持有 `[any RepoSource]`，按顺序询问每一个源
//  - 命中：返回 `Resolution`（含 sourceName / repo / 元信息），停止询问
//  - 未命中（nil）：继续询问下一个
//  - throws：捕获 + 打 warning 日志 + 跳过此源继续询问下一个
//  - 链全部失败的兜底由 `MinimalRepoSource`（永远命中）保证；不应该走到这里之外
//
//  ────────────────────────────────────────────────────────────────────────────
//  Resolution.isLocalHit
//  ────────────────────────────────────────────────────────────────────────────
//
//  各场景 ContentView 的关键决策点：
//  - `isLocalHit == true` → 已 star，渲染 tags / notes / release 三段
//  - `isLocalHit == false` → 未 star，三段不渲染（设计 §3.2.6）
//
//  约定：只有 `LocalRepoSource` 命中才算 isLocalHit = true。其他源虽然返回的
//  Repo 也可能恰好 isStarred = true（如 GitHub `/repos` 响应里 `viewer_starred`，
//  R-01 暂未消费此字段），但都视为「非本地真值」，让三段判断更稳定。
//

import Foundation

/// 一次 resolve 的结果。
struct RepoResolution: Sendable {
    /// 命中源的 name（用于日志 / debug）。
    let sourceName: String

    /// 解析出来的 Repo（永远非 nil，因 chain 末尾 MinimalRepoSource 兜底）。
    let repo: Repo

    /// 是否来自 LocalRepoSource（本地 SQLite 真值）。
    /// 各场景 ContentView 用此决定是否渲染 tags / notes / release 三段。
    let isLocalHit: Bool

    /// 是否最终走到了 MinimalRepoSource（chain 全部前面的源失败）。
    /// UI 层可以选择性显示 warning（如顶部 banner「无法获取最新数据」）。
    let isMinimal: Bool
}

/// 详情页 Repo 解析链。
///
/// 用法：
/// ```swift
/// let resolution = await resolver.resolve(owner: "alice", name: "foo", hint: nil)
/// // resolution.repo 永远非 nil
/// if resolution.isLocalHit { /* 渲染 tags / notes / release */ }
/// ```
@MainActor
final class RepoResolver {

    let chain: [any RepoSource]

    init(chain: [any RepoSource]) {
        self.chain = chain
    }

    /// 按顺序询问 chain，返回首个命中。
    ///
    /// **不抛错**：链中任一 source throws，本方法 catch + 打 warning + 跳过。
    /// 如果调用方需要拿到「具体哪一步失败」的详细信息（如 trending 详情显示
    /// 「⚠️ 无法获取最新数据」），通过 `resolution.isMinimal` 判断即可。
    func resolve(owner: String, name: String, hint: StarcatRepoCardDTO? = nil) async -> RepoResolution {
        for source in chain {
            do {
                if let repo = try await source.tryResolve(owner: owner, name: name, hint: hint) {
                    let isLocalHit = (source is LocalRepoSource)
                    let isMinimal = (source is MinimalRepoSource)
                    AppLog.sync.info("RepoResolver hit: \(source.name, privacy: .public) (\(owner, privacy: .public)/\(name, privacy: .public), localHit=\(isLocalHit, privacy: .public), minimal=\(isMinimal, privacy: .public))")
                    return RepoResolution(
                        sourceName: source.name,
                        repo: repo,
                        isLocalHit: isLocalHit,
                        isMinimal: isMinimal
                    )
                }
            } catch {
                AppLog.sync.warning("RepoResolver source \(source.name, privacy: .public) threw: \(error.localizedDescription, privacy: .public) (\(owner, privacy: .public)/\(name, privacy: .public))")
                continue
            }
        }

        // 理论不可达：链末尾 MinimalRepoSource 永远命中。
        // 兜底：构造一个最小 Repo 直接返回，避免 force unwrap 崩溃。
        AppLog.sync.error("RepoResolver: all sources failed unexpectedly (chain misconfigured?). Falling back to MinimalRepoSource directly.")
        return RepoResolution(
            sourceName: "MinimalRepoSource (forced)",
            repo: Repo.makeMinimal(owner: owner, name: name, hint: hint),
            isLocalHit: false,
            isMinimal: true
        )
    }
}
