//
//  FTSQuery.swift
//  Starcat
//
//  FTS5 查询字符串工具。
//
//  问题背景：
//  - 用户输入直接拼到 FTS5 MATCH 子句会引发语法错误（如 `-rust`, `swift+ui`, `"hello`）
//  - FTS5 元字符: " * ^ : ( ) AND OR NOT NEAR + - 等
//  - 我们要做的是"用户感知到的关键词搜索"，不暴露 FTS5 高级语法
//
//  策略（与 GitHub 搜索框一致的行为）：
//  - 按空白拆词
//  - 每个词用双引号包裹（FTS5 双引号转义只需把 `"` 替换为 `""`）
//  - 末尾词追加 `*` 实现前缀匹配（用户边输入边出结果时体验更好）
//  - 多词之间默认 AND 关系
//
//  示例：
//  - 输入 `swift ui` → `"swift" "ui"*`
//  - 输入 `react.js` → `"react.js"*`
//  - 输入 `c++ template` → `"c++" "template"*`
//  - 输入 `   ` → 调用方自行处理空字符串，本工具不返回空 query
//

import Foundation

/// FTS5 查询字符串构造工具。
enum FTSQuery {

    /// 把用户原文转为合法的 FTS5 MATCH 表达式。
    ///
    /// - Parameter rawInput: 用户原始输入，必须已 trim 过；调用方负责空字符串短路。
    /// - Returns: 形如 `"foo" "bar"*` 的 FTS5 字符串。
    static func sanitize(_ rawInput: String) -> String {
        let tokens = rawInput
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return "" }

        let escaped = tokens.map(escapeToken)

        // 最后一个 token 加前缀通配，其余精确匹配
        if escaped.count == 1 {
            return "\(escaped[0])*"
        } else {
            let head = escaped.dropLast().joined(separator: " ")
            let tail = escaped.last!  // safe: escaped.count >= 2
            return "\(head) \(tail)*"
        }
    }

    /// 单个 token 包双引号 + 内部 `"` 转义为 `""`（FTS5 规范）。
    private static func escapeToken(_ token: String) -> String {
        let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
