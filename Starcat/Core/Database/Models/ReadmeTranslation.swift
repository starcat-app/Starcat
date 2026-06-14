//
//  ReadmeTranslation.swift
//  Starcat
//
//  README AI 翻译结果缓存模型（HOM-68 / 2026-06-15 砍 DB 改纯磁盘缓存 v2）。
//
//  模块职责：
//  - 表达「某仓库 README 在某目标语言下的最新翻译」；
//  - 持有 `sourceHash` 让上层判断原 README 是否已被作者更新（避免误用旧译文）；
//  - 记录使用的 LLM 模型名，便于复盘 / 后续多模型对比；
//  - 字段全部走 `<owner>/<repo>/<lang>.json` 磁盘 metadata 序列化。
//
//  关键约束：
//  - 这是「AI 输出缓存」，不是「原 README 缓存」（后者由 `Readme` / `readmes` 表负责）。
//  - **v2 起完全脱离 GRDB**：本类型不再实现 `FetchableRecord`/`PersistableRecord`，
//    存储改为 `DiskReadmeTranslationCache` 单点负责（`<owner>/<repo>/<lang>.{html,json}`）。
//    背景：原 v1 用 `readme_translations` 表 + `repo_id FK → repos.id`，但 trending /
//    activity / weekly 详情页的 repo 大多数未本地 star → `repos` 表无对应 row →
//    `INSERT INTO readme_translations` 撞 SQLite error 19。dong4j 决策："翻译资产不
//    应该被 star 状态削减，未 star 也能翻译查看；DB 改纯磁盘单一存储"。
//  - 字段语义和 readmes 表对齐（`translatedHtml` ↔ `rendered_html`、`size` 同义），
//    让 UI 端可以直接喂给 `ReadmeWebView` 渲染，无需二次包装。
//  - `repoId` 字段保留为可选——磁盘 cache 路径不依赖它（路径用 owner/repo），但
//    服务层透传到 record 里方便未来如有 starred-only 索引需求时可读到，不强制要求。
//

import Foundation

/// README 翻译缓存。
///
/// 字段说明见 `CodingKeys` 上方注释。snake_case JSON key 与 v1 GRDB 表列名保持一致，
/// 是为了让既有 fixture / 测试样例能零改动迁移（虽然 v1 的 DB 已经砍，但 JSON shape
/// 维持稳定能减少不必要的 churn）。
struct ReadmeTranslation: Codable, Equatable, Sendable {

    /// 关联 GitHub 仓库 ID。磁盘 cache 路径不依赖它，但服务层在写入时透传保留，
    /// 用于排查 / 日志 / 未来如要做 starred-only 索引时可派上用场。
    /// 可选：trending / activity ephemeral repo 可能拿不到真实 id（极少数情况）。
    var repoId: Int64?

    /// 目标语言（BCP-47 风格 raw，如 `zh-Hans` / `en` / `ja`）。
    ///
    /// 不直接持 `ReadmeTranslationLanguage` 枚举：枚举属于 Core/Settings，
    /// Models 层保持纯数据；UI / Service 层自行做 enum ↔ raw 转换。
    var targetLanguage: String

    /// 使用的 LLM 模型名（如 `gpt-4o-mini` / `deepseek-chat`）。
    ///
    /// 当用户改了任务对应的模型后旧译文仍可被命中——是否复用由上层 `sourceHash`
    /// 决定，不在这里做"模型不同自动作废"的硬规则，避免用户切换模型后丢失所有
    /// 已生成的中文译文（成本沉重）。
    var model: String

    /// 参与翻译的原 README HTML 指纹（SHA256 十六进制串）。
    ///
    /// 上层判断缓存是否仍可复用：当前 readmes.rendered_html 的指纹与本字段一致才
    /// 算「内容未变」；不一致需要用户主动重新翻译（避免静默吃 AI 配额做隐式翻译）。
    var sourceHash: String

    /// 模型回填后的 HTML 片段。
    ///
    /// 结构与 `readmes.rendered_html` 完全对齐：是 GitHub HTML render 端点返回的
    /// 那种「不含 <html>/<head>/<body>」的片段，可以直接喂给 `ReadmeWebView` 渲染。
    var translatedHtml: String

    /// 翻译结果字节数（UTF-8）。便于缓存清理按字节排序，与 `readmes.size` 同义。
    var size: Int

    /// 写入时间，ISO8601。供 UI 展示「翻译于 ...」。
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case repoId = "repo_id"
        case targetLanguage = "target_language"
        case model
        case sourceHash = "source_hash"
        case translatedHtml = "translated_html"
        case size
        case createdAt = "created_at"
    }
}
