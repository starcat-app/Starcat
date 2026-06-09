//
//  BackendHintRepoSource.swift
//  Starcat
//
//  R-01 RepoSource chain 第二节：用列表传过来的 backend DTO 直接构造临时 Repo。
//
//  ────────────────────────────────────────────────────────────────────────────
//  适用场景
//  ────────────────────────────────────────────────────────────────────────────
//
//  - Trending / Weekly 列表已经从后端拉过 `StarcatRepoCardDTO`（含 stars / forks /
//    topics / language 等大部分字段），点详情进入时把 hint 透传给 RepoResolver；
//    这里**零网络 IO** 直接转 in-memory Repo，详情页 hero 立刻有数据。
//  - 用户已 star 时被 LocalRepoSource 优先命中（更全 + 是真实持久化数据）；
//    未 star 时本源命中为详情页提供「列表见到什么 → 详情看到什么」的视觉一致性。
//
//  ────────────────────────────────────────────────────────────────────────────
//  ⚠️ Owner / Name 大小写匹配防御（v1.2 dong4j review R3.4）
//  ────────────────────────────────────────────────────────────────────────────
//
//  极端边界：列表 hint DTO 是 `alice/Foo`，详情页 owner/name 由 URL path 拼成
//  `Alice/foo`。GitHub 实际是 case-insensitive 解析（同一仓库），但本机字符串
//  比较是 case-sensitive。
//
//  如果不防御，hint 与入参大小写不一致 → 严格相等失败 → 误判为不同仓库 →
//  跳到 GitHubFallbackRepoSource 多走一次网络。
//
//  防御措施：用 `caseInsensitiveCompare` 容忍大小写差异，让同一仓库即使大小写
//  不同也能命中 hint。当 owner/repo 真正不同（如 hint 串配错）时仍然返 nil
//  让链继续询问下一个源。
//

import Foundation

struct BackendHintRepoSource: RepoSource {
    let name = "BackendHintRepoSource"

    func tryResolve(owner: String, name: String, hint: StarcatRepoCardDTO?) async throws -> Repo? {
        guard let hint else { return nil }

        // case-insensitive 匹配防御：owner / repo 任一大小写不一致都跳过
        guard hint.owner.caseInsensitiveCompare(owner) == .orderedSame,
              hint.repo.caseInsensitiveCompare(name) == .orderedSame
        else {
            return nil
        }
        return hint.toEphemeralRepo()
    }
}
