//
//  MinimalRepoSource.swift
//  Starcat
//
//  R-01 RepoSource chain 第五节（兜底）：永远命中，构造最小可用 Repo。
//
//  ────────────────────────────────────────────────────────────────────────────
//  适用场景
//  ────────────────────────────────────────────────────────────────────────────
//
//  - 整条 chain 全部 throws 或返回 nil（极端罕见：本地无 + hint 不匹配 + 后端聚合
//    占位返 nil + GitHub API 也挂掉）
//  - 详情页此时**不能白屏**，必须有最低限度的 hero（fullName + owner / name）+
//    GitHub 外链（让用户至少能点链接到浏览器）
//
//  ────────────────────────────────────────────────────────────────────────────
//  契约
//  ────────────────────────────────────────────────────────────────────────────
//
//  - **永远命中**（不返回 nil 也不 throws）
//  - 优先用 hint 字段（DTO 已经有 stars / forks / topics），让 hero 更丰满
//  - 没有 hint 时只有 owner/name；`Repo.id = 0`（非合法 GitHub id），调用方
//    应用 `id == 0` 判断「无法 star/unstar」从而禁用对应 chip
//

import Foundation

struct MinimalRepoSource: RepoSource {
    let name = "MinimalRepoSource"

    func tryResolve(owner: String, name: String, hint: StarcatRepoCardDTO?) async throws -> Repo? {
        // 永远命中。Repo.makeMinimal 内部判断有无 hint，没有就走纯 owner/name 路径。
        Repo.makeMinimal(owner: owner, name: name, hint: hint)
    }
}
