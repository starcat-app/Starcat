//
//  ReadmeTranslation.swift
//  Starcat
//
//  README AI 翻译结果缓存模型，对应 `readme_translations` 表（HOM-68）。
//
//  模块职责：
//  - 表达「某仓库 README 在某目标语言下的最新翻译」，单一 PK `(repo_id, target_language)`；
//  - 持有 `source_hash` 让上层判断原 README 是否已被作者更新（避免误用旧译文）；
//  - 记录使用的 LLM 模型名，便于复盘 / 后续多模型对比。
//
//  关键约束：
//  - 这是「AI 输出缓存」，不是「原 README 缓存」（后者由 `Readme` / `readmes` 表负责）。
//  - 字段语义和 readmes 表对齐（`translated_html` ↔ `rendered_html`、`size` 同义），
//    让 UI 端可以直接喂给 `ReadmeWebView` 渲染，无需二次包装。
//

import Foundation
import GRDB

/// README 翻译缓存。
struct ReadmeTranslation: Codable, FetchableRecord, MutablePersistableRecord, Equatable, Sendable {

    static let databaseTableName = "readme_translations"

    /// 关联仓库 ID（外键 → repos.id ON DELETE CASCADE）。
    var repoId: Int64

    /// 目标语言（BCP-47 风格 raw，如 `zh-Hans` / `en` / `ja`）。
    ///
    /// 不直接持 `ReadmeTranslationLanguage` 枚举：枚举属于 Core/Settings，
    /// Models 层保持纯数据；UI / Service 层自行做 enum ↔ raw 转换。
    var targetLanguage: String

    /// 使用的 LLM 模型名（如 `gpt-4o-mini` / `deepseek-chat`）。
    ///
    /// 当用户改了任务对应的模型后旧译文仍可被命中——是否复用由上层 `source_hash`
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
