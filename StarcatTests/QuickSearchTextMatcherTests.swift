//
//  QuickSearchTextMatcherTests.swift
//  StarcatTests
//
//  快速搜索文本归一化与跨字段匹配的回归测试。
//

import Testing
@testable import Starcat

@Suite("QuickSearchTextMatcher")
struct QuickSearchTextMatcherTests {

    /// 空查询必须保留所有行，否则关闭搜索框后列表会继续处于过滤状态。
    @Test("空查询匹配任意候选字段")
    func emptyQueryMatches() {
        #expect(QuickSearchTextMatcher.matches("  ", candidates: [nil, "owner/repo"]))
    }

    /// 仓库名、说明等字段共用同一条本地化大小写不敏感规则。
    @Test("忽略大小写并跨字段匹配")
    func matchesAcrossFieldsIgnoringCase() {
        #expect(QuickSearchTextMatcher.matches("STARCAT", candidates: ["dong4j/starcat", nil]))
        #expect(QuickSearchTextMatcher.matches("知识库", candidates: ["Repository", "AI 知识库工具"]))
        #expect(!QuickSearchTextMatcher.matches("missing", candidates: ["dong4j/starcat", "AI 知识库工具"]))
    }

    /// 未搜索时不应解码任何评论候选；已翻页行数越多，提前返回越能保护滚动主线程。
    @Test("空查询不派生任何行的候选文本")
    func emptyQuerySkipsCandidateProjection() {
        let rows = Array(0..<400)
        var projectedCount = 0
        let result = QuickSearchTextMatcher.filter(rows, query: " \n ") { row in
            projectedCount += 1
            return [String(row)]
        }
        #expect(result == rows)
        #expect(projectedCount == 0)
    }

    /// 真正搜索仍逐行检查一次，保持原有跨字段、大小写和原始排序语义。
    @Test("搜索快照每行只派生一次并保留匹配顺序")
    func searchProjectsEachRowOnce() {
        let rows = ["starcat-app/Starcat", "other/repo", "dong4j/starcat"]
        var projectedRows: [String] = []
        let result = QuickSearchTextMatcher.filter(rows, query: " STARCAT ") { row in
            projectedRows.append(row)
            return [nil, row]
        }
        #expect(result == [rows[0], rows[2]])
        #expect(projectedRows == rows)
    }
}
