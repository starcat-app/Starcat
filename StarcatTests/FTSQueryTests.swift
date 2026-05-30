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
