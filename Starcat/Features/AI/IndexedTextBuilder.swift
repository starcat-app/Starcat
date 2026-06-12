//
//  IndexedTextBuilder.swift
//  Starcat
//
//  把 Repo / README / AI 摘要 / 用户笔记拼成 `IndexedSnapshot` 与最终喂模型的字符串。
//  详见 `docs/详细设计/26-向量搜索改进.md` § 2 / 3.1。
//
//  模块职责：
//  - `buildSnapshot(repo:readme:summary:note:)` → 拼成结构化快照（落 `snapshot_json`）
//  - `render(snapshot:)` → 把快照拼成 embedding 模型的输入字符串
//
//  关键约束：
//  - **三级降级主体**（决策 D / dong4j 2026-06-12 决策）：
//      1. AI 摘要存在且非空 → 用摘要（最语义化、最稳定）
//      2. README 存在 → 用 `ReadmePreprocessor` 处理后的纯文本
//      3. 都没有 → 用 `description + topics` 兜底
//    无论走哪级，**元数据尾巴和用户笔记永远拼接**（dong4j 2026-06-12：
//    "三级降级策略只适用于自然语言主体，元数据/笔记永远会被拼上"）。
//  - **元数据字段筛选**（决策 D）：保留 fullName / description / language / topics /
//    license / homepage，剔除 stars / forks / owner / name / 时间戳；
//    避免 stars / forks 高频变化引起 diff 永远超阈值。
//  - **buildSnapshot 是 pure 函数**：不读 settings / 不调网络，方便单测；
//    截断长度等可配置项必须由调用方传入。
//  - `render(snapshot:)` 输出的字符串只用于"喂 embedding 模型"，不要再用于 diff 判定
//    （diff 走结构化 snapshot，避免顺序变化误判）。
//

import Foundation

enum IndexedTextBuilder {

    // MARK: - 构建快照

    /// 把 repo 元数据 + 数据源拼成 `IndexedSnapshot`。
    ///
    /// - Parameters:
    ///   - repo: 仓库基础信息（必须）
    ///   - readmePlainText: 已经过 `ReadmePreprocessor.process(html:/markdown:)` 处理的纯文本；
    ///     调用方负责清洗与截断。传 nil 表示没有可用 README。
    ///   - aiSummary: AI 摘要的 Markdown 文本（如果用户已生成过）；传 nil 表示无摘要。
    ///   - noteContent: 用户私有笔记的 Markdown 文本；传 nil / 空串表示无笔记。
    static func buildSnapshot(
        repo: Repo,
        readmePlainText: String?,
        aiSummary: String?,
        noteContent: String?
    ) -> IndexedSnapshot {
        let body = chooseBody(
            aiSummary: aiSummary,
            readmePlainText: readmePlainText,
            repo: repo
        )
        let notes = normalizeOptional(noteContent)
        let metadata = IndexedSnapshot.Metadata(
            fullName: repo.fullName,
            description: normalizeOptional(repo.description),
            language: normalizeOptional(repo.language),
            topics: normalizeTopics(repo.topics),
            license: normalizeOptional(repo.license),
            homepage: normalizeOptional(repo.homepage)
        )
        return IndexedSnapshot(body: body, notes: notes, metadata: metadata)
    }

    // MARK: - 渲染最终字符串

    /// 把 snapshot 拼成 embedding 模型的输入字符串。
    ///
    /// 输出顺序（固定）：
    /// ```
    /// Repository: {fullName}
    /// Description: {description}
    /// Language: {language}
    /// Topics: {topics}
    /// License: {license}
    /// Homepage: {homepage}
    /// {body}
    /// Notes:
    /// {notes}
    /// ```
    /// 顺序固定的目的：让生成出的 text 在元数据相同时只有 body / notes 顺序差异，
    /// 便于日志诊断 / 抓包对比。
    static func render(snapshot: IndexedSnapshot) -> String {
        var lines: [String] = []
        lines.append("Repository: \(snapshot.metadata.fullName)")
        lines.append("Description: \(snapshot.metadata.description ?? "")")
        lines.append("Language: \(snapshot.metadata.language ?? "")")
        lines.append("Topics: \(snapshot.metadata.topics ?? "")")
        lines.append("License: \(snapshot.metadata.license ?? "")")
        lines.append("Homepage: \(snapshot.metadata.homepage ?? "")")
        if !snapshot.body.isEmpty {
            lines.append(snapshot.body)
        }
        if let notes = snapshot.notes, !notes.isEmpty {
            lines.append("Notes:")
            lines.append(notes)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 私有：三级降级主体

    /// 三级降级选取主体（决策 D）：AI 摘要 > README 纯文本 > description+topics 兜底。
    ///
    /// 兜底层不再附加 "Description: ..." 前缀（防止跟元数据尾巴重复），只把 description
    /// 与 topics 拼成一段自然语言主体——
    /// 如果连这两个都为空，body 就是空字符串，metadata 单独承担描述性。
    private static func chooseBody(
        aiSummary: String?,
        readmePlainText: String?,
        repo: Repo
    ) -> String {
        if let summary = normalizeOptional(aiSummary), !summary.isEmpty {
            return summary
        }
        if let readme = normalizeOptional(readmePlainText), !readme.isEmpty {
            return readme
        }
        // 兜底：description + topics（不带前缀，避免与元数据尾巴的 "Description:" 重复）
        var parts: [String] = []
        if let desc = normalizeOptional(repo.description) {
            parts.append(desc)
        }
        let topics = repo.topicsArray
        if !topics.isEmpty {
            parts.append(topics.joined(separator: ", "))
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - 私有：归一化

    /// `nil` / 空白字符串统一变 `nil`，避免 `Optional<String>("")` 与 `Optional<String>.none`
    /// 在 `IndexedSnapshot.Metadata` Equatable 比较时被判定为不等。
    private static func normalizeOptional(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    /// 把 `repos.topics`（JSON 数组字符串）归一化为 "a, b, c" 形式，方便：
    /// 1. metadata diff 比较稳定（不受 JSON whitespace 影响）
    /// 2. embedding 模型读到逗号分隔列表，比裸 JSON 更自然
    /// 解析失败时回退到原始字符串。
    private static func normalizeTopics(_ topicsJSON: String?) -> String? {
        guard let topicsJSON = normalizeOptional(topicsJSON) else { return nil }
        guard let data = topicsJSON.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data)
        else {
            return topicsJSON
        }
        let normalized = array
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return normalized.isEmpty ? nil : normalized.joined(separator: ", ")
    }
}
