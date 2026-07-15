//
//  SemanticSearchTests.swift
//  StarcatTests
//
//  AI 语义搜索本地逻辑测试。
//
//  覆盖范围：
//  - Float32 embedding 与 SQLite BLOB 之间的无损编解码；
//  - cosine similarity 的排序基础。
//
//  不覆盖真实 AI 网络调用：BYOK provider 会随用户配置变化，单测只验证 Starcat 本地可控逻辑。
//

import Testing
import Foundation
@testable import Starcat

@Suite("Semantic Search")
struct SemanticSearchTests {

    @Test("RepoEmbedding: Float32 BLOB 编解码保持数值")
    func embeddingBlobRoundTrip() {
        let vector: [Float] = [0.1, -0.2, 0.3, 1.0]
        let data = RepoEmbedding.encode(vector)
        #expect(RepoEmbedding.decode(data) == vector)
    }

    @Test("cosine similarity: 同向最高，正交为 0")
    func cosineSimilarity() {
        let same = SemanticSearchService.cosineSimilarity([1, 0, 0], [1, 0, 0])
        let orthogonal = SemanticSearchService.cosineSimilarity([1, 0, 0], [0, 1, 0])
        let opposite = SemanticSearchService.cosineSimilarity([1, 0], [-1, 0])

        #expect(abs(same - 1.0) < 0.0001)
        #expect(abs(orthogonal - 0.0) < 0.0001)
        #expect(abs(opposite + 1.0) < 0.0001)
    }

    @Test("Accelerate 余弦内核与 Double 标量基准保持一致")
    func acceleratedCosineMatchesScalarReference() {
        let lhs = (0..<1_024).map { Float(sin(Double($0) * 0.13)) }
        let rhs = (0..<1_024).map { Float(cos(Double($0) * 0.07)) }
        let accelerated = CosineSimilarityQuery(lhs).similarity(to: rhs)
        let dot = zip(lhs, rhs).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        let lhsNorm = sqrt(lhs.reduce(0.0) { $0 + Double($1) * Double($1) })
        let rhsNorm = sqrt(rhs.reduce(0.0) { $0 + Double($1) * Double($1) })

        #expect(abs(accelerated - dot / (lhsNorm * rhsNorm)) < 0.000_001)
        #expect(CosineSimilarityQuery([]).similarity(to: []).isNaN)
        #expect(CosineSimilarityQuery([1, 0]).similarity(to: [1]).isNaN)
        #expect(CosineSimilarityQuery([0, 0]).similarity(to: [1, 0]).isNaN)
    }

    // MARK: - 2026-06-14 A+B 改造：纯函数级单测

    @Test("normalizeDisplayScore: 经验区间 [0.30, 0.95] 线性映射到 [0, 1]")
    func normalizeDisplayScore() {
        let f = SemanticSearchService.normalizeDisplayScore
        #expect(abs(f(0.30) - 0.0) < 0.0001, "下界 0.30 → 0%")
        #expect(abs(f(0.95) - 1.0) < 0.0001, "上界 0.95 → 100%")
        // 中间点：(0.625 - 0.30) / (0.95 - 0.30) = 0.5
        #expect(abs(f(0.625) - 0.5) < 0.0001)
        // 用户截图 case：cosine 0.68 → (0.68 - 0.30) / 0.65 ≈ 0.585
        #expect(abs(f(0.68) - 0.5846) < 0.001)
        // 旧默认阈值 0.75 cosine → ~0.692 displayScore
        #expect(abs(f(0.75) - 0.6923) < 0.001)
    }

    @Test("normalizeDisplayScore: 超出区间应被 clamp 到 [0, 1]")
    func normalizeDisplayScoreClamp() {
        let f = SemanticSearchService.normalizeDisplayScore
        #expect(f(0.0) == 0.0)
        #expect(f(-0.5) == 0.0)
        #expect(f(1.0) == 1.0)
        #expect(f(2.0) == 1.0)
    }

    @Test("normalizeDisplayScore: NaN 输入返回 0")
    func normalizeDisplayScoreNaN() {
        #expect(SemanticSearchService.normalizeDisplayScore(.nan) == 0)
    }

    @Test("tier(forDisplayScore:) 4 档边界")
    func tierBoundaries() {
        let f = SemanticSearchService.tier(forDisplayScore:)
        #expect(f(1.0) == 4)
        #expect(f(0.85) == 4)
        #expect(f(0.84) == 3)
        #expect(f(0.65) == 3)
        #expect(f(0.64) == 2)
        #expect(f(0.45) == 2)
        #expect(f(0.44) == 1)
        #expect(f(0.0) == 1)
    }

    @Test("hasLiteralMatch: fullName 子串命中（owner 单独不在 description 里也算）")
    func literalMatchFullName() {
        let repo = makeRepo(fullName: "google/guava", description: "java helpers", topics: nil)
        #expect(SemanticSearchService.hasLiteralMatch(repo: repo, query: "google"))
        #expect(SemanticSearchService.hasLiteralMatch(repo: repo, query: "guava"))
        #expect(SemanticSearchService.hasLiteralMatch(repo: repo, query: "google/guava"))
    }

    @Test("hasLiteralMatch: description 命中")
    func literalMatchDescription() {
        let repo = makeRepo(
            fullName: "vendor/tool",
            description: "fewer tokens, fewer tool calls, 100% local",
            topics: nil
        )
        // 用户截图核心 case：query 完整出现在 description
        #expect(SemanticSearchService.hasLiteralMatch(repo: repo, query: "fewer tokens, fewer tool calls, 100% local"))
        #expect(SemanticSearchService.hasLiteralMatch(repo: repo, query: "100% local"))
    }

    @Test("hasLiteralMatch: topics JSON 字符串命中")
    func literalMatchTopics() {
        let repo = makeRepo(fullName: "u/r", description: "x", topics: "[\"ai\",\"local-llm\"]")
        #expect(SemanticSearchService.hasLiteralMatch(repo: repo, query: "local-llm"))
        // topics 是 JSON 字符串，里面的引号 / 中括号也能被子串匹配，符合"字面命中"语义
        #expect(SemanticSearchService.hasLiteralMatch(repo: repo, query: "ai"))
    }

    @Test("hasLiteralMatch: 大小写不敏感")
    func literalMatchCaseInsensitive() {
        let repo = makeRepo(fullName: "Google/Guava", description: "Java Helpers", topics: nil)
        #expect(SemanticSearchService.hasLiteralMatch(repo: repo, query: "google"))
        #expect(SemanticSearchService.hasLiteralMatch(repo: repo, query: "JAVA"))
    }

    @Test("hasLiteralMatch: 完全无关 query 应返回 false")
    func literalMatchMiss() {
        let repo = makeRepo(fullName: "google/guava", description: "java helpers", topics: nil)
        #expect(!SemanticSearchService.hasLiteralMatch(repo: repo, query: "kubernetes"))
    }

    @Test("常量约束：literal boost floor / fts boost weight 在合理范围")
    func constantsAreSane() {
        // literal boost 必须 ≥ displayScore 高档阈值 (4 星 = 0.85)
        // 否则字面命中也不一定显示 4★，违背"字面命中应是高度相关"的产品意图
        #expect(SemanticSearchService.literalBoostFloor >= 0.85)
        #expect(SemanticSearchService.literalBoostFloor <= 1.0)
        // fts boost 必须 < 经验区间跨度，否则会让弱相关被一路推到顶档
        let span = SemanticSearchService.displayScoreHighAnchor - SemanticSearchService.displayScoreLowAnchor
        #expect(SemanticSearchService.ftsBoostWeight < span)
        #expect(SemanticSearchService.ftsBoostWeight > 0)
    }

    // MARK: - helpers

    private func makeRepo(fullName: String, description: String?, topics: String?) -> Repo {
        let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
        let owner = parts.count == 2 ? parts[0] : ""
        let name = parts.count == 2 ? parts[1] : fullName
        return Repo(
            id: 1,
            owner: owner,
            name: name,
            fullName: fullName,
            description: description,
            language: nil,
            starsCount: 0,
            forksCount: 0,
            watchersCount: 0,
            topics: topics,
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/\(fullName)",
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
}

@Suite("Repo AI Insight")
struct RepoAIInsightTests {

    @Test("AI Insight: 可从包裹在 markdown fence 中的 JSON 解码")
    func decodeFencedJSON() throws {
        let raw = """
        ```json
        {
          "oneLiner": "一个 Swift 网络库",
          "summary": "用于测试 JSON 解码。",
          "platforms": ["Swift"],
          "suitableFor": ["macOS App"],
          "strengths": ["轻量"],
          "risks": ["维护状态未知"],
          "minimalExample": null,
          "suggestedTags": [
            {"name": "Swift", "confidence": 0.9, "reason": "主要语言"}
          ],
          "model": "",
          "generatedAt": ""
        }
        ```
        """

        let insight = try RepoAIInsightService.decodeInsight(json: raw)
        #expect(insight.oneLiner == "一个 Swift 网络库")
        #expect(insight.suggestedTags.first?.name == "Swift")
    }

    @Test("AI Tags: 可解析 suggestedTags envelope")
    func decodeTagEnvelope() throws {
        let raw = """
        {
          "suggestedTags": [
            {"name": "local-ai", "confidence": 0.82, "reason": "本地模型相关"}
          ]
        }
        """

        let tags = try RepoAIInsightService.decodeTagSuggestions(json: raw)
        #expect(tags.count == 1)
        #expect(tags[0].name == "local-ai")
    }

    @MainActor
    @Test("AI 输出语言跟随 Starcat Display Language")
    func outputLanguageFollowsDisplayLanguage() {
        let oldSelection = LocaleStore.shared.selection
        defer { LocaleStore.shared.selection = oldSelection }

        LocaleStore.shared.selection = .english
        #expect(RepoAIInsightService.outputLanguageDescriptor() == "English")

        LocaleStore.shared.selection = .simplifiedChinese
        #expect(RepoAIInsightService.outputLanguageDescriptor() == "Simplified Chinese")
    }

    @MainActor
    @Test("AI 摘要缓存 key 按输出语言隔离")
    func cacheModelKeyIncludesOutputLanguage() throws {
        let oldSelection = LocaleStore.shared.selection
        defer { LocaleStore.shared.selection = oldSelection }

        let suiteName = "test.starcat.ai-cache-language.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let keychain = InMemoryKeychain()
        let database = try InMemoryDatabaseManager()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let service = RepoAIInsightService(
            summaryRepository: GRDBAISummaryRepository(database: database),
            readmeRepository: ReadmeRepository(database: database),
            settings: settings,
            keychain: keychain
        )

        LocaleStore.shared.selection = .english
        let englishKey = service.cacheModelKey()

        LocaleStore.shared.selection = .simplifiedChinese
        let chineseKey = service.cacheModelKey()

        #expect(englishKey.contains("lang:English|"))
        #expect(chineseKey.contains("lang:Simplified Chinese|"))
        #expect(englishKey != chineseKey)
    }
}
