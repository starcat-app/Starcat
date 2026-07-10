//
//  AgentErrorSanitizerTests.swift
//  StarcatTests
//
//  验证 Agent 错误进入持久化和 UI 前不会暴露常见凭证格式。
//

import Testing
@testable import Starcat

@Suite("AgentErrorSanitizer")
struct AgentErrorSanitizerTests {
    @Test("Authorization、API key 和 OpenAI key 会被脱敏")
    func redactsCredentials() {
        let message = "Authorization: Bearer secret-token api_key=private-key sk-abcdefgh12345678"

        let sanitized = AgentErrorSanitizer.sanitize(message)

        #expect(!sanitized.contains("secret-token"))
        #expect(!sanitized.contains("private-key"))
        #expect(!sanitized.contains("sk-abcdefgh12345678"))
        #expect(sanitized.contains("[REDACTED]"))
    }

    @Test("超长 Provider 错误会被限制长度")
    func boundsProviderErrors() {
        let sanitized = AgentErrorSanitizer.sanitize(String(repeating: "x", count: 2_000))

        #expect(sanitized.hasSuffix("[truncated]"))
        #expect(sanitized.count < 1_050)
    }
}
