//
//  CompanionRequestParserTests.swift
//  StarcatTests
//
//  覆盖 Chrome Companion 本机 HTTP parser 的安全边界。
//

import Foundation
import Testing
@testable import Starcat

@Suite("CompanionRequestParser")
struct CompanionRequestParserTests {
    @Test("解析 GET request line, query 与大小写归一 header")
    func parsesRequest() throws {
        let raw = """
        GET /local/v1/repo-context?owner=apple&repo=swift HTTP/1.1\r
        Host: 127.0.0.1:5051\r
        Origin: chrome-extension://abc\r
        Authorization: Bearer token\r
        \r

        """

        let request = try CompanionRequestParser.parse(Data(raw.utf8))

        #expect(request.method == "GET")
        #expect(request.path == "/local/v1/repo-context")
        #expect(request.query["owner"] == "apple")
        #expect(request.query["repo"] == "swift")
        #expect(request.headers["origin"] == "chrome-extension://abc")
        #expect(request.headers["authorization"] == "Bearer token")
        #expect(request.body.isEmpty)
    }

    @Test("重复 query key 返回错误而不是触发 Dictionary trap")
    func rejectsDuplicateQueryKey() throws {
        let raw = "GET /local/v1/repo-context?owner=apple&owner=swift HTTP/1.1\r\n\r\n"

        #expect(throws: CompanionHTTPRequestError.duplicateQueryKey("owner")) {
            _ = try CompanionRequestParser.parse(Data(raw.utf8))
        }
    }

    @Test("重复 header 采用 first value, 保持 parser 不崩溃")
    func keepsFirstDuplicateHeader() throws {
        let raw = """
        GET /local/v1/ping HTTP/1.1\r
        Authorization: Bearer first\r
        Authorization: Bearer second\r
        \r

        """

        let request = try CompanionRequestParser.parse(Data(raw.utf8))
        #expect(request.headers["authorization"] == "Bearer first")
    }

    @Test("非法 request line 被拒绝")
    func rejectsMalformedRequestLine() throws {
        let raw = "GET /local/v1/ping\r\n\r\n"

        #expect(throws: CompanionHTTPRequestError.malformedRequest) {
            _ = try CompanionRequestParser.parse(Data(raw.utf8))
        }
    }

    @Test("超大 body 被拒绝")
    func rejectsLargeBody() throws {
        var data = Data("POST /local/v1/notes HTTP/1.1\r\n\r\n".utf8)
        data.append(Data(repeating: UInt8(ascii: "a"), count: CompanionRequestParser.maximumBodyBytes + 1))

        #expect(throws: CompanionHTTPRequestError.bodyTooLarge) {
            _ = try CompanionRequestParser.parse(data)
        }
    }
}
