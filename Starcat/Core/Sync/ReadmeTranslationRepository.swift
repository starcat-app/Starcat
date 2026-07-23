//
//  ReadmeTranslationRepository.swift
//  Starcat
//
//  README AI 翻译缓存 Repository 协议（HOM-68 v2 / 2026-06-15 砍 DB 走纯磁盘）。
//
//  模块职责：
//  - 仅定义协议 + 让上层 service / 测试 / 装配可以面向协议依赖。
//  - **v2 起没有 GRDB 实现**：唯一实现是 `DiskReadmeTranslationCache`（位于
//    `Shared/Services/DiskReadmeTranslationCache.swift`），背后是文件系统而非数据库。
//
//  关键约束（v2 切换背景，写给后续接手者）：
//  - **为什么砍 DB**：trending / activity / weekly 详情页的 repo 大多数未本地 star
//    → `repos` 表无对应 row → 原 v1 `INSERT INTO readme_translations` 因
//    `repo_id FK → repos.id` 撞 SQLite error 19；产品也明确"翻译资产不该被 star
//    状态削减"。综合查阅工程没有任何其它系统消费 `readme_translations` 表
//    （CloudKit 同步 / FTS 全文 / JSON 导入导出 / 设置页缓存管理全 0 引用），
//    DB 表的全部"理由"都是惯性，砍掉无任何业务损失。
//  - **接口由 `(repoId, language)` 改为 `(owner, repo, language, mode)`**：磁盘 cache 路径
//    用 `<owner>/<repo>/<lang>[.full].json`，让 Finder 用户可读，与 RepoContextStorage
//    / CodeFlowStorage 一致。trending repo 拿不到稳定 ID 时（极少），owner/repo 在
//    上游 DTO 里始终是真值。
//  - **依旧协议化**：service 持有 `any ReadmeTranslationRepositoryProtocol` 注入，便于
//    单测注入 in-memory mock；生产装配走 `DiskReadmeTranslationCache.shared`。
//

import Foundation

/// README 翻译缓存协议。
///
/// 实现位于 `DiskReadmeTranslationCache`（生产）/ 测试用 in-memory mock 自行实现。
/// **所有方法都是 `@MainActor`**：唯一实现 `DiskReadmeTranslationCache` 是
/// `@MainActor @Observable final class`，且 service 本身就是 `@MainActor`。
@MainActor
protocol ReadmeTranslationRepositoryProtocol {
    /// 查找指定 owner/repo + 目标语言 + 翻译方式的最新翻译；未命中返 nil。
    /// **副作用**：实现内可能更新 lastAccessedAt（mtime），用于 LRU。
    func find(
        owner: String,
        repo: String,
        targetLanguage: String,
        mode: ReadmeTranslationMode
    ) async throws -> ReadmeTranslation?

    /// 写入翻译产物（PK 等价于 `(owner, repo, targetLanguage, mode)`，重复 key 覆盖）。
    func upsert(
        _ translation: ReadmeTranslation,
        owner: String,
        repo: String,
        mode: ReadmeTranslationMode
    ) async throws

    /// 删除指定 owner/repo 在某语言和方式下的翻译（当前 UI 未接，保留协议方法）。
    func delete(
        owner: String,
        repo: String,
        targetLanguage: String,
        mode: ReadmeTranslationMode
    ) async throws

    /// 删除指定 owner/repo 的所有语言译文（CASCADE 等价；当前业务无人调，保留协议方法）。
    func deleteAll(owner: String, repo: String) async throws

    /// 清掉全部翻译缓存（设置页"清除翻译缓存"按钮入口）。
    func deleteEverything() async throws
}
