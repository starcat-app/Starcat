//
//  SemanticIndexingTests.swift
//  StarcatTests
//
//  向量索引改进（2026-06-12）单元测试。
//
//  覆盖范围：
//  - `ReadmePreprocessor`：HTML / Markdown 清洗 + 截断的边界
//  - `IndexedSnapshot`：Codable / Equatable
//  - `IndexedTextBuilder`：三级降级主体 + 元数据筛选 + 笔记拼接
//  - `IndexedTextDiff`：行级 diff 比例计算 + 三档阈值 + metadata 变化触发
//
//  设计取舍：
//  - 测试不打 SQLite、不打网络、不调 LLM；全部走 pure function 路径
//  - 数据用最小可复现样本（5-10 行），失败时人类一眼能看出差在哪里
//

import Testing
import Foundation
@testable import Starcat

// MARK: - ReadmePreprocessor

@Suite("ReadmePreprocessor")
struct ReadmePreprocessorTests {

    @Test("HTML: 删 <script> / <style> / <img>")
    func htmlStripsKnownNoise() {
        let html = """
        <h1>Title</h1>
        <script>alert('x')</script>
        <style>body { color: red; }</style>
        <img src="a.png" alt="x">
        <p>Body</p>
        """
        let cleaned = ReadmePreprocessor.process(html: html)
        #expect(cleaned.contains("Title"))
        #expect(cleaned.contains("Body"))
        #expect(!cleaned.contains("alert"))
        #expect(!cleaned.contains("color:"))
        #expect(!cleaned.contains("<img"))
    }

    @Test("HTML: 解码 entity")
    func htmlDecodesEntities() {
        let html = "<p>A &amp; B &lt;tag&gt; &quot;q&quot; &#39;a&#39; &nbsp;end</p>"
        let cleaned = ReadmePreprocessor.process(html: html)
        #expect(cleaned.contains("A & B"))
        #expect(cleaned.contains("<tag>"))
        #expect(cleaned.contains("\"q\""))
        #expect(cleaned.contains("'a'"))
        #expect(cleaned.contains("end"))
    }

    @Test("HTML: 截断按字符数")
    func htmlTruncates() {
        let long = String(repeating: "A", count: 20_000)
        let cleaned = ReadmePreprocessor.process(html: long, maxLength: 12_000)
        #expect(cleaned.count == 12_000)
    }

    @Test("Markdown: 删图片 / 保留段落分隔")
    func markdownPreservesLineBreaks() {
        let md = """
        # Title

        ![alt](https://example.com/a.png)

        Para 1



        Para 2
        """
        let cleaned = ReadmePreprocessor.process(markdown: md)
        // 多个空行被压成单个空行 → 段落仍可见
        #expect(cleaned.contains("Title"))
        #expect(cleaned.contains("Para 1"))
        #expect(cleaned.contains("Para 2"))
        #expect(!cleaned.contains("![alt]"))
        // 保留换行（行级 diff 依赖）
        #expect(cleaned.contains("\n"))
    }

    @Test("空字符串 → 空")
    func emptyInputs() {
        #expect(ReadmePreprocessor.process(html: "").isEmpty)
        #expect(ReadmePreprocessor.process(markdown: "").isEmpty)
    }
}

// MARK: - IndexedSnapshot

@Suite("IndexedSnapshot")
struct IndexedSnapshotTests {

    @Test("Codable: 编码 / 解码往返")
    func codableRoundTrip() throws {
        let snapshot = IndexedSnapshot(
            body: "Hello\nWorld",
            notes: "private note",
            metadata: IndexedSnapshot.Metadata(
                fullName: "owner/repo",
                description: "desc",
                language: "Swift",
                topics: "ai, ios",
                license: "MIT",
                homepage: "https://example.com"
            )
        )
        let json = try snapshot.encodedJSONString()
        let decoded = try IndexedSnapshot.decode(json: json)
        #expect(decoded == snapshot)
    }

    @Test("Metadata Equatable: 字段不等即不等")
    func metadataEquatable() {
        let a = IndexedSnapshot.Metadata(fullName: "x/y", description: "d")
        let b = IndexedSnapshot.Metadata(fullName: "x/y", description: "d")
        let c = IndexedSnapshot.Metadata(fullName: "x/y", description: "different")
        #expect(a == b)
        #expect(a != c)
    }
}

// MARK: - IndexedTextBuilder

@Suite("IndexedTextBuilder")
struct IndexedTextBuilderTests {

    private func makeRepo(
        fullName: String = "owner/repo",
        description: String? = "Test desc",
        language: String? = "Swift",
        topics: String? = "[\"ai\",\"ios\"]",
        license: String? = "MIT",
        homepage: String? = "https://h.example"
    ) -> Repo {
        Repo(
            id: 1,
            owner: "owner",
            name: "repo",
            fullName: fullName,
            description: description,
            language: language,
            starsCount: 100,
            forksCount: 10,
            watchersCount: 5,
            topics: topics,
            license: license,
            homepage: homepage,
            htmlUrl: "https://github.com/owner/repo",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: true,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: nil
        )
    }

    @Test("三级降级: 优先用 AI 摘要")
    func bodyPrefersSummary() {
        let repo = makeRepo()
        let snap = IndexedTextBuilder.buildSnapshot(
            repo: repo,
            readmePlainText: "readme text",
            aiSummary: "ai summary text",
            noteContent: nil
        )
        #expect(snap.body == "ai summary text")
    }

    @Test("三级降级: 无摘要时用 README")
    func bodyFallsBackToReadme() {
        let repo = makeRepo()
        let snap = IndexedTextBuilder.buildSnapshot(
            repo: repo,
            readmePlainText: "readme text",
            aiSummary: nil,
            noteContent: nil
        )
        #expect(snap.body == "readme text")
    }

    @Test("三级降级: 摘要 README 全空 → description+topics 兜底")
    func bodyFallsBackToDescriptionTopics() {
        let repo = makeRepo(description: "fallback desc", topics: "[\"a\",\"b\"]")
        let snap = IndexedTextBuilder.buildSnapshot(
            repo: repo,
            readmePlainText: nil,
            aiSummary: nil,
            noteContent: nil
        )
        #expect(snap.body.contains("fallback desc"))
        #expect(snap.body.contains("a, b"))
    }

    @Test("元数据筛选: 不收 stars / forks / owner / name / 时间戳")
    func metadataIgnoresVolatileFields() {
        let repo = makeRepo()
        let snap = IndexedTextBuilder.buildSnapshot(
            repo: repo,
            readmePlainText: "x",
            aiSummary: nil,
            noteContent: nil
        )
        #expect(snap.metadata.fullName == "owner/repo")
        // 验证 metadata 结构里没有 stars / forks 等字段（编译期保证：IndexedSnapshot.Metadata
        // 没声明这些属性）；如果未来不小心加上 stars 字段，编译失败时会让人重新审视决策 D。
        let mirror = Mirror(reflecting: snap.metadata)
        let labels = mirror.children.compactMap { $0.label }
        #expect(!labels.contains("starsCount"))
        #expect(!labels.contains("forksCount"))
        #expect(!labels.contains("owner"))
        #expect(!labels.contains("name"))
        #expect(!labels.contains("cachedAt"))
    }

    @Test("Topics JSON 数组归一化为逗号分隔")
    func topicsNormalized() {
        let repo = makeRepo(topics: "[\"ai\",\"ios\",\"swift\"]")
        let snap = IndexedTextBuilder.buildSnapshot(
            repo: repo, readmePlainText: "x", aiSummary: nil, noteContent: nil
        )
        #expect(snap.metadata.topics == "ai, ios, swift")
    }

    @Test("笔记拼到 render 输出末尾")
    func notesAppendedAtEnd() {
        let repo = makeRepo()
        let snap = IndexedTextBuilder.buildSnapshot(
            repo: repo,
            readmePlainText: "BODY",
            aiSummary: nil,
            noteContent: "MY NOTE"
        )
        let text = IndexedTextBuilder.render(
            snapshot: snap,
            userPromptTemplate: AIDefaultPrompts.embedding.userPromptTemplate
        )
        #expect(text.contains("BODY"))
        #expect(text.contains("Notes:"))
        #expect(text.contains("MY NOTE"))
        // 笔记必须在 body 之后
        let bodyRange = text.range(of: "BODY")
        let notesRange = text.range(of: "MY NOTE")
        #expect(bodyRange != nil && notesRange != nil && bodyRange!.lowerBound < notesRange!.lowerBound)
    }
}

// MARK: - IndexedTextDiff

@Suite("IndexedTextDiff")
struct IndexedTextDiffTests {

    private func snapshot(
        body: String = "line1\nline2\nline3\nline4\nline5",
        notes: String? = nil,
        full: String = "owner/repo",
        desc: String? = "d"
    ) -> IndexedSnapshot {
        IndexedSnapshot(
            body: body,
            notes: notes,
            metadata: IndexedSnapshot.Metadata(fullName: full, description: desc)
        )
    }

    @Test("旧快照不存在 → 必须重建")
    func oldNilTriggers() {
        let new = snapshot()
        #expect(IndexedTextDiff.shouldRebuild(old: nil, new: new, thresholds: .default))
    }

    @Test("metadata 任一字段变 → 必须重建")
    func metadataChangeTriggers() {
        let old = snapshot(desc: "old")
        let new = snapshot(desc: "new")
        #expect(IndexedTextDiff.shouldRebuild(old: old, new: new, thresholds: .default))
    }

    @Test("body 完全相同 → 不重建")
    func bodyUnchanged() {
        let old = snapshot()
        let new = snapshot()
        #expect(!IndexedTextDiff.shouldRebuild(old: old, new: new, thresholds: .default))
    }

    @Test("body 改 1/5 (20%) > 10% 阈值 → 重建")
    func bodyOverBodyRatio() {
        let old = snapshot(body: "a\nb\nc\nd\ne")
        let new = snapshot(body: "a\nb\nc\nd\nE")
        // 对称差 = {e, E} = 2, max = 5 → 0.4 > 0.10
        #expect(IndexedTextDiff.shouldRebuild(old: old, new: new, thresholds: .default))
    }

    @Test("notes 阈值独立判定")
    func notesRatioIndependent() {
        let old = snapshot(notes: "n1\nn2\nn3\nn4\nn5\nn6\nn7\nn8\nn9\nn10")
        let new = snapshot(notes: "n1\nn2\nn3\nn4\nn5\nn6\nn7\nn8\nn9\nNEW")
        // 对称差 = {n10, NEW} = 2, max = 10 → 0.2 == 0.2 阈值 → 不重建（严格大于）
        #expect(!IndexedTextDiff.shouldRebuild(old: old, new: new, thresholds: .default))
        // 再多改一行 → 超 0.2 → 重建
        let newer = snapshot(notes: "n1\nn2\nn3\nn4\nn5\nn6\nn7\nn8\nNEW1\nNEW2")
        #expect(IndexedTextDiff.shouldRebuild(old: old, new: newer, thresholds: .default))
    }

    @Test("lineDiffRatio: 空 vs 空 = 0")
    func ratioBothEmpty() {
        #expect(IndexedTextDiff.lineDiffRatio(old: "", new: "") == 0)
    }

    @Test("lineDiffRatio: 空 vs 非空 = 1")
    func ratioOneEmpty() {
        #expect(IndexedTextDiff.lineDiffRatio(old: "", new: "x\ny") == 1)
        #expect(IndexedTextDiff.lineDiffRatio(old: "x\ny", new: "") == 1)
    }

    @Test("lineDiffRatio: 完全相同 = 0")
    func ratioIdentical() {
        let t = "a\nb\nc"
        #expect(IndexedTextDiff.lineDiffRatio(old: t, new: t) == 0)
    }

    @Test("三档预设阈值")
    func presetThresholds() {
        #expect(AIIndexPreset.strict.thresholds.bodyDiffRatio == 0.05)
        #expect(AIIndexPreset.standard.thresholds.bodyDiffRatio == 0.10)
        #expect(AIIndexPreset.relaxed.thresholds.bodyDiffRatio == 0.20)
    }
}
