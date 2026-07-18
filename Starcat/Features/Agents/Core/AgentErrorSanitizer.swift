//
//  AgentErrorSanitizer.swift
//  Starcat
//
//  Agent 用户可见错误的最后一道敏感信息过滤。
//
//  Provider SDK 的错误文本可能包含 Authorization、API key 或请求片段。Runtime 在写入
//  数据库、工作台和统一日志前统一经过这里，避免凭证进入长期审计事实。
//

import Foundation

enum AgentErrorSanitizer {
    private static let maximumCharacters = 1_000

    static func sanitize(_ message: String) -> String {
        let replacements: [(pattern: String, template: String)] = [
            (#"(?i)(authorization\s*[:=]\s*)(?:bearer\s+)?[^\s,;]+"#, "$1[REDACTED]"),
            (#"(?i)(api[_ -]?key\s*[:=]\s*)[^\s,;]+"#, "$1[REDACTED]"),
            (#"(?i)bearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer [REDACTED]"),
            (#"sk-[A-Za-z0-9_-]{8,}"#, "[REDACTED]")
        ]
        let redacted = replacements.reduce(message) { partial, replacement in
            partial.replacingOccurrences(
                of: replacement.pattern,
                with: replacement.template,
                options: .regularExpression
            )
        }
        guard redacted.count > maximumCharacters else { return redacted }
        return String(redacted.prefix(maximumCharacters)) + "\n[truncated]"
    }
}
