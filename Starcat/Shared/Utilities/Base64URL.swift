//
//  Base64URL.swift
//  Starcat
//
//  2026-06-29：Data 的 base64url 编码扩展。
//
//  用途：PKCE 协议（RFC 7636）要求 `code_verifier` 和 `code_challenge` 用 base64url 编码
//  （无 padding / `+` 替成 `-` / `/` 替成 `_`）以适配 URL 参数。
//
//  标准 base64 的字符集是 `A-Z a-z 0-9 + /`，但 base64url 用 `-` 和 `_` 替换两个 URL
//  不安全字符，让编码串可以直接拼到 URL query 里。
//

import Foundation

extension Data {
    /// base64url 编码（无 padding）。
    /// - 替换 `+` → `-`
    /// - 替换 `/` → `_`
    /// - 删除末尾 `=` padding
    func base64URLEncodedString() -> String {
        let standard = self.base64EncodedString()
        return standard
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// base64url 解码（兼容带或不带 padding）。
    static func fromBase64URL(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // 补齐 padding
        let padding = (4 - s.count % 4) % 4
        s += String(repeating: "=", count: padding)
        return Data(base64Encoded: s)
    }
}
