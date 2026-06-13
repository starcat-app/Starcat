//
//  TierTruncationTests.swift
//  StarcatTests
//
//  验证 TierTruncation.tier1Head 的双约束截断逻辑（§22.9 Q8 决议）：
//    - 行数上限 80 + 字符数上限 4000
//    - 都未超 → 原文
//    - 仅行数超 → 头 80 行 + showing marker
//    - 仅字符数超 → 前 4000 字符 + exceeded chars marker
//    - 同时超 → 走字符数 marker（更严格）
//

import Testing
@testable import Starcat

@Suite("TierTruncation.tier1Head")
struct TierTruncationTests {

    @Test("空字符串返回空字符串")
    func emptyInput() {
        #expect(TierTruncation.tier1Head("") == "")
    }

    @Test("短文本（< 80 行 + < 4000 字符）原样返回")
    func shortText() {
        let text = "line 1\nline 2\nline 3"
        let result = TierTruncation.tier1Head(text)
        #expect(result == text)
        // 不应含 truncated marker
        #expect(!result.contains("[truncated"))
    }

    @Test("Windows 换行 \\r\\n 归一化")
    func windowsLineEndings() {
        let text = "line 1\r\nline 2\r\nline 3"
        let result = TierTruncation.tier1Head(text)
        // 归一化后是 \n
        #expect(result == "line 1\nline 2\nline 3")
        // 不应再含 \r
        #expect(!result.contains("\r"))
    }

    @Test("行数超 80 → 头 80 行 + showing marker")
    func exceedsLines() {
        // 构造 100 行，每行 5 字符（总 ≈ 500 字符，不会触发字符上限）
        let lines = (1...100).map { "L\($0)" }.joined(separator: "\n")
        let result = TierTruncation.tier1Head(lines)
        #expect(result.contains("[truncated: showing first 80 of 100 lines]"))
        // 不应含 exceeded chars marker
        #expect(!result.contains("exceeded"))
    }

    @Test("字符数超 4000 但行数不超 80 → exceeded chars marker")
    func exceedsCharsOnly() {
        // 1 行 5000 字符（minified JS 场景）
        let longLine = String(repeating: "a", count: 5000)
        let result = TierTruncation.tier1Head(longLine)
        #expect(result.contains("[truncated: exceeded 4000 chars]"))
        // 不应含 showing marker
        #expect(!result.contains("showing"))
    }

    @Test("行数和字符数都超 → 字符数 marker 优先（更严格）")
    func exceedsBoth() {
        // 100 行 × 60 字符 = 6000 字符 + 100 行
        let lines = (1...100).map { _ in String(repeating: "x", count: 60) }
            .joined(separator: "\n")
        let result = TierTruncation.tier1Head(lines)
        // 因为字符数超 4000，走字符路径
        #expect(result.contains("exceeded 4000 chars"))
    }

    @Test("常量值与设计文档一致")
    func constants() {
        #expect(TierTruncation.tier0MaxBytes == 100 * 1024)
        #expect(TierTruncation.tier1MaxLines == 80)
        #expect(TierTruncation.tier1MaxChars == 4000)
        #expect(TierTruncation.singleFileMaxBytes == 5 * 1024 * 1024)
    }
}
