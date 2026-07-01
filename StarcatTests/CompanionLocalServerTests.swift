//
//  CompanionLocalServerTests.swift
//  StarcatTests
//
//  验证 Chrome Companion 本机 HTTP 服务的最小安全外壳。
//

import Foundation
import Testing
@testable import Starcat

@Suite("CompanionLocalServer")
@MainActor
struct CompanionLocalServerTests {
    private func makeServer() throws -> CompanionLocalServer {
        let keychain = InMemoryKeychain()
        try keychain.storeCompanionToken("test-token")
        let defaults = try #require(UserDefaults(suiteName: "CompanionLocalServerTests.\(UUID().uuidString)"))
        return CompanionLocalServer(
            configuration: CompanionConfiguration(secureStore: keychain, defaults: defaults)
        )
    }

    @Test("GET /local/v1/ping 带 token 返回 200")
    func pingReturnsOK() throws {
        let server = try makeServer()
        let response = server.handle(request("""
        GET /local/v1/ping HTTP/1.1\r
        Origin: chrome-extension://abc\r
        Authorization: Bearer test-token\r
        \r

        """))

        #expect(statusCode(response) == 200)
        #expect(bodyString(response).contains("\"status\":\"ok\""))
        #expect(header(response, "Access-Control-Allow-Origin") == "chrome-extension://abc")
    }

    @Test("缺 token 返回 401")
    func missingTokenReturnsUnauthorized() throws {
        let server = try makeServer()
        let response = server.handle(request("GET /local/v1/ping HTTP/1.1\r\n\r\n"))

        #expect(statusCode(response) == 401)
        #expect(bodyString(response).contains("unauthorized"))
    }

    @Test("非 extension origin 返回 403")
    func forbiddenOrigin() throws {
        let server = try makeServer()
        let response = server.handle(request("""
        GET /local/v1/ping HTTP/1.1\r
        Origin: https://github.com\r
        Authorization: Bearer test-token\r
        \r

        """))

        #expect(statusCode(response) == 403)
    }

    @Test("OPTIONS 预检通过 Origin 校验但不要求 token")
    func optionsDoesNotRequireToken() throws {
        let server = try makeServer()
        let response = server.handle(request("""
        OPTIONS /local/v1/ping HTTP/1.1\r
        Origin: chrome-extension://abc\r
        \r

        """))

        #expect(statusCode(response) == 204)
        #expect(header(response, "Access-Control-Allow-Private-Network") == "true")
    }

    @Test("未知路径返回 404")
    func unknownPathReturnsNotFound() throws {
        let server = try makeServer()
        let response = server.handle(request("""
        GET /local/v1/missing HTTP/1.1\r
        Authorization: Bearer test-token\r
        \r

        """))

        #expect(statusCode(response) == 404)
    }

    private func request(_ raw: String) -> Data {
        Data(raw.utf8)
    }

    private func statusCode(_ data: Data) -> Int? {
        guard let firstLine = String(data: data, encoding: .utf8)?
            .components(separatedBy: "\r\n")
            .first else { return nil }
        return Int(firstLine.split(separator: " ").dropFirst().first ?? "")
    }

    private func header(_ data: Data, _ key: String) -> String? {
        guard let raw = String(data: data, encoding: .utf8),
              let headerEnd = raw.range(of: "\r\n\r\n") else { return nil }
        let target = key.lowercased()
        for line in raw[..<headerEnd.lowerBound].components(separatedBy: "\r\n").dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if name == target { return value }
        }
        return nil
    }

    private func bodyString(_ data: Data) -> String {
        guard let raw = String(data: data, encoding: .utf8),
              let headerEnd = raw.range(of: "\r\n\r\n") else { return "" }
        return String(raw[headerEnd.upperBound...])
    }
}
