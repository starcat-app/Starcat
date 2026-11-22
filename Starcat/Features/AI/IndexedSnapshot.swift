//
//  IndexedSnapshot.swift
//  Starcat
//
//  向量索引"上次进过模型的快照"结构（详见 `docs/3-设计/详细设计/26-向量搜索改进.md`）。
//
//  模块职责：
//  - 替代旧 `content_hash` 方案，把"喂过 embedding 模型的内容"拆成 body / notes /
//    metadata 三部分结构化保存；
//  - 让 `IndexedTextDiff` 能在不同维度（行级 diff vs 任一字段不等）做差异判定，而不是
//    像 hash 一样"任何字段变就全等不成立"。
//
//  关键约束：
//  - **必须 Codable**：完整快照会以压缩 JSON 落到 `repo_embeddings.snapshot_payload`；
//    新增 / 改名字段必须考虑 JSON 兼容性（产品上线前可任意改，上线后只能加非必选字段）；
//  - **必须 Equatable**：`IndexedTextDiff.shouldRebuild` 依赖 metadata 元组的相等比较；
//  - **metadata 只放"语义稳定"的字段**：fullName / description / language / topics /
//    license / homepage。决策 D 已剔除 stars / forks / owner / name / 时间戳——
//    这些字段高频变化但不影响"这是个 X 项目"的语义，纳入会让 diff 永远超阈值。
//

import Foundation

/// 向量索引快照：上次实际进过 embedding 模型的内容结构化记录。
///
/// 调用方典型用法：
/// ```swift
/// // 构建本次"应该索引的"快照
/// let new = IndexedTextBuilder.buildSnapshot(repo: repo, readme: readme, summary: summary, note: note)
/// // 与上次实际索引的快照比对
/// if IndexedTextDiff.shouldRebuild(old: old, new: new, thresholds: thresholds) {
///     let text = IndexedTextBuilder.render(snapshot: new, userPromptTemplate: template)
///     // ...调 embedding API...
/// }
/// ```
struct IndexedSnapshot: Codable, Equatable, Sendable {

    /// 主体内容：AI 摘要与 README 并存（摘要在前），都没有才用 description+topics。
    /// 行级 diff 在这里跑；Search Center 字面加分也会扫 `body`。
    var body: String

    /// 用户私有笔记纯文本（可空）；与 body 单独 diff，阈值更宽松（默认 20%）。
    /// 笔记是高频小幅修改的"个人笔记本"场景，body 阈值（默认 10%）会触发风暴。
    var notes: String?

    /// 元数据元组（决策 D 保留字段）。任一字段变化即判定需要重建。
    var metadata: Metadata

    struct Metadata: Codable, Equatable, Sendable {
        var fullName: String
        var description: String?
        var language: String?
        var topics: String?
        var license: String?
        var homepage: String?

        init(
            fullName: String,
            description: String? = nil,
            language: String? = nil,
            topics: String? = nil,
            license: String? = nil,
            homepage: String? = nil
        ) {
            self.fullName = fullName
            self.description = description
            self.language = language
            self.topics = topics
            self.license = license
            self.homepage = homepage
        }
    }

    init(body: String, notes: String? = nil, metadata: Metadata) {
        self.body = body
        self.notes = notes
        self.metadata = metadata
    }

    // MARK: - Codec

    /// 保留完整快照的 Codable Schema，压缩只用于持久化。
    func encodedPayload() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try CacheJSONCodec.pack(encoder.encode(self))
    }

    /// 从 SQLite 取出的 BLOB 还原结构。失败时调用方应当走"无旧快照"分支
    /// （`IndexedTextDiff.shouldRebuild` 中 `old == nil` 即触发重建），不应阻塞流程。
    static func decode(payload: Data) throws -> IndexedSnapshot {
        try JSONDecoder().decode(IndexedSnapshot.self, from: CacheJSONCodec.unpack(payload))
    }
}
