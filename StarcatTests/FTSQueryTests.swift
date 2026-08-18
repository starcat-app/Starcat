//
//  FTSQueryTests.swift
//  StarcatTests
//
//  验证 FTSQuery.sanitize 在边界输入下不会构造非法 FTS5 表达式。
//

import Testing
@testable import Starcat

@Suite("FTSQuery.sanitize")
struct FTSQueryTests {

    @Test("单词加前缀通配")
    func singleToken() {
        let q = FTSQuery.sanitize("swift")
        #expect(q == "\"swift\"*")
    }

    @Test("多词：前面精确 + 末尾通配")
    func multipleTokens() {
        let q = FTSQuery.sanitize("react native")
        #expect(q == "\"react\" \"native\"*")
    }

    @Test("含双引号要转义为两个双引号")
    func escapesQuotes() {
        let q = FTSQuery.sanitize("say\"hi")
        // 转义后单 token 表达
        #expect(q.contains("\"\""))
    }

    @Test("元字符（+ - .）被引号包裹后不再触发 FTS5 语法")
    func neutralizesMetaCharacters() {
        let q = FTSQuery.sanitize("c++ template -rust")
        // 不应出现裸的 - 在词首 → 用 \" 包围所有 token
        #expect(q.starts(with: "\""))
        #expect(q.hasSuffix("*"))
    }

    @Test("全空白返回空字符串（由调用方短路）")
    func emptyAfterTrim() {
        let q = FTSQuery.sanitize("   ")
        #expect(q == "")
    }
}

@Suite("RAGKeywordQueryBuilder")
struct RAGKeywordQueryBuilderTests {
    @Test("多个双语关键词使用安全 OR，短语保持原子查询")
    func bilingualTermsUseOR() {
        let query = RAGKeywordQueryBuilder.build(
            keywordQueries: ["配置", "build target", "OR", "say\"hi", "配置"],
            semanticQuery: "ignored fallback"
        )
        #expect(query.terms == ["配置", "build target", "OR", "say\"hi"])
        #expect(query.sqliteFTS5Expression == "\"配置\"* OR \"build target\"* OR \"OR\"* OR \"say\"\"hi\"*")
        #expect(query.externalQuery == "配置 build target OR say\"hi")
        #expect(!query.usedSemanticFallback)
    }

    @Test("旧 Prompt 缺少关键词时从语义查询构建有界 OR")
    func semanticFallbackDropsFillerAndCapsTerms() {
        let query = RAGKeywordQueryBuilder.build(
            keywordQueries: [],
            semanticQuery: "Introduction and overview of the repository vector database indexing configuration command extra"
        )
        #expect(query.terms == ["vector", "database", "indexing", "configuration", "command", "extra"])
        #expect(query.sqliteFTS5Expression.contains("\"vector\"* OR \"database\"*"))
        #expect(query.usedSemanticFallback)
    }

    @Test("关键词长度、数量和大小写去重受本地边界约束")
    func termsAreBounded() {
        let long = String(repeating: "a", count: 100)
        let query = RAGKeywordQueryBuilder.build(
            keywordQueries: ["Swift", "swift", long] + (0..<12).map { "term-\($0)" },
            semanticQuery: ""
        )
        #expect(query.terms.count == RAGKeywordQueryBuilder.maximumTermCount)
        #expect(query.terms[0] == "Swift")
        #expect(query.terms[1].count == RAGKeywordQueryBuilder.maximumTermLength)
    }

    @Test("原句身份词进入关键词队头，中文整句不会变成 LIKE term")
    func identityTermsComeFromLatinAnchorsOnly() {
        let terms = RAGKeywordQueryBuilder.identityTerms(
            from: "查一下 starcat 相关的项目, 告诉我这些项目是干嘛的"
        )
        #expect(terms == ["starcat"])
        #expect(!terms.contains(where: { $0.contains("项目") }))

        let ownerRepo = RAGKeywordQueryBuilder.identityTerms(from: "看看 starcat-app/starcat-pro")
        #expect(ownerRepo.contains("starcat-app/starcat-pro"))
        #expect(ownerRepo.contains("starcat-app"))
        #expect(ownerRepo.contains("starcat-pro"))
    }

    @Test("Planner 关键词挤满时仍保留原句身份词")
    func anchorQuestionPrependsIdentityBeforePlannedTerms() {
        let planned = (0..<8).map { "topic-\($0)" }
        let query = RAGKeywordQueryBuilder.build(
            keywordQueries: planned,
            semanticQuery: "these projects",
            anchorQuestion: "查一下 starcat 相关的项目"
        )
        #expect(query.terms.first == "starcat")
        #expect(query.terms.contains("topic-0"))
        #expect(query.terms.count == RAGKeywordQueryBuilder.maximumTermCount)
        #expect(!query.terms.contains("topic-7"))
        #expect(!query.usedSemanticFallback)
    }
}
