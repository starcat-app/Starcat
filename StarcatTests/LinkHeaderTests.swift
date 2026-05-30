//
//  LinkHeaderTests.swift
//  StarcatTests
//
//  覆盖 GitHub Link 头解析的常见与异常场景。
//

import Testing
import Foundation
@testable import Starcat

@Suite("LinkHeader.parse")
struct LinkHeaderTests {

    @Test("空字符串应返回 nil/nil")
    func empty() {
        let r = LinkHeader.parse(nil)
        #expect(r.nextPage == nil)
        #expect(r.lastPage == nil)
    }

    @Test("典型的 next + last")
    func typical() {
        let header = #"<https://api.github.com/user/starred?per_page=100&page=2>; rel="next", <https://api.github.com/user/starred?per_page=100&page=50>; rel="last""#
        let r = LinkHeader.parse(header)
        #expect(r.nextPage == 2)
        #expect(r.lastPage == 50)
    }

    @Test("只有 prev 时 next/last 都为 nil")
    func onlyPrev() {
        let header = #"<https://api.github.com/user/starred?per_page=100&page=49>; rel="prev""#
        let r = LinkHeader.parse(header)
        #expect(r.nextPage == nil)
        #expect(r.lastPage == nil)
    }

    @Test("URL 中带其他参数不影响 page 提取")
    func multipleQuery() {
        let header = #"<https://api.github.com/user/starred?sort=created&per_page=100&page=3&direction=desc>; rel="next""#
        let r = LinkHeader.parse(header)
        #expect(r.nextPage == 3)
    }

    @Test("格式异常时应容错返回 nil 而非 crash")
    func malformed() {
        let header = "not a valid link header"
        let r = LinkHeader.parse(header)
        #expect(r.nextPage == nil)
        #expect(r.lastPage == nil)
    }
}
