//
//  XMLEscapeTests.swift
//  StarcatTests
//
//  验证 XMLEscape 的两个 escape 点（§22.10 Q9 决议）：
//    - CDATA 拆段（`]]>` → `]]]]><![CDATA[>`）
//    - 属性值 5 个标准字符转义（& < > " '）
//

import Testing
@testable import Starcat

@Suite("XMLEscape")
struct XMLEscapeTests {

    // MARK: - escapeCDATA

    @Test("CDATA 无终止序列时原样返回")
    func cdataNoTerminator() {
        let text = "hello <world> & 'stuff'"
        #expect(XMLEscape.escapeCDATA(text) == text)
    }

    @Test("CDATA 含 ]]> 拆段")
    func cdataSplitTerminator() {
        let text = "before ]]> after"
        let escaped = XMLEscape.escapeCDATA(text)
        // 拆段算法：]]> → ]]]]><![CDATA[>
        #expect(escaped == "before ]]]]><![CDATA[> after")
    }

    @Test("CDATA 多次 ]]> 全部拆段")
    func cdataMultipleTerminators() {
        let text = "a ]]> b ]]> c"
        let escaped = XMLEscape.escapeCDATA(text)
        // 两次拆段
        #expect(escaped == "a ]]]]><![CDATA[> b ]]]]><![CDATA[> c")
    }

    // MARK: - escapeAttribute

    @Test("属性值无元字符原样返回")
    func attributeNoMetaChars() {
        let text = "src/index.ts"
        #expect(XMLEscape.escapeAttribute(text) == text)
    }

    @Test("属性值 5 个标准字符全转义")
    func attributeAllMetaChars() {
        let text = "& < > \" '"
        let escaped = XMLEscape.escapeAttribute(text)
        #expect(escaped == "&amp; &lt; &gt; &quot; &apos;")
    }

    @Test("& 先于其它字符替换（避免引入新 &）")
    func ampersandFirst() {
        // 如果 < 先替换，会生成 `&lt;` 然后 & 又被替换为 `&amp;lt;` → 错
        let text = "<a>"
        let escaped = XMLEscape.escapeAttribute(text)
        #expect(escaped == "&lt;a&gt;")  // 而不是 &amp;lt;a&amp;gt;
    }

    @Test("属性值含 & 不会被双重 escape")
    func ampersandNotDoubled() {
        let text = "AT&T"
        #expect(XMLEscape.escapeAttribute(text) == "AT&amp;T")
    }
}
