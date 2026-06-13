// MARK: - GlobCompiler
//
// glob → NSRegularExpression 转换器（§22.3 Q2 决议）。
//
// 支持的语法：
//   - `*`        — 单目录内任意字符（不跨 `/`）
//   - `**`       — 跨目录任意路径
//   - `?`        — 单字符（不跨 `/`）
//   - `{a,b,c}`  — 字符类（多选一）
//   - 元字符 `. ( ) + $ ^ | [ ] \` 自动转义
//
// **case-sensitive** 匹配（默认）—— 因为 GitHub 仓库大多 case-sensitive（Linux / macOS APFS）；
// `README.md` 与 `readme.md` 是不同文件。
//
// 设计权衡（§22.3）：
//   ✅ 零依赖、约 50 行可控
//   ✅ NSRegularExpression 性能足够（实测 5000 文件 × 100 pattern < 100ms）
//   ❌ 不用第三方 lib（Foundation 已有 NSPredicate 但 LIKE 语法不支持 `**`）
//
// 性能优化：caller（TierRules 加载时）应该把所有 pattern 一次性 compile 成 [NSRegularExpression]
// 缓存，避免每个文件重新编译。

import Foundation

public enum GlobCompileError: Error {
    /// `{...}` 没有匹配的 `}`。
    case unmatchedBrace(pattern: String, index: Int)
}

public enum GlobCompiler {

    /// 把 glob pattern 编译成 NSRegularExpression（case-sensitive）。
    ///
    /// **算法**：单次扫描原 pattern，逐字符追加到目标 regex pattern。
    ///   - 遇 `*` peek 下一位：是 `*` → `.*`（**），否则 `[^/]*`（*）
    ///   - 遇 `?` → `[^/]`
    ///   - 遇 `{` 找到匹配 `}`，split by `,`，逐项 `escapedPattern(for:)` → `(a|b|c)`
    ///   - 遇 regex 元字符 → 转义
    ///   - 其它字符 → 原样
    ///
    /// - Parameter glob: glob 表达式（如 `src/**/*.{ts,tsx}`）
    /// - Returns: 编译后的 NSRegularExpression
    /// - Throws: `GlobCompileError.unmatchedBrace`
    public static func toRegex(_ glob: String) throws -> NSRegularExpression {
        var pattern = "^"
        var i = glob.startIndex

        while i < glob.endIndex {
            let c = glob[i]

            switch c {
            case "*":
                let next = glob.index(after: i)
                if next < glob.endIndex && glob[next] == "*" {
                    // ** 跨目录
                    pattern += ".*"
                    i = glob.index(after: next)
                    continue
                } else {
                    // * 单目录内
                    pattern += "[^/]*"
                }

            case "?":
                pattern += "[^/]"

            case "{":
                guard let endIndex = glob[i...].firstIndex(of: "}") else {
                    let position = glob.distance(from: glob.startIndex, to: i)
                    throw GlobCompileError.unmatchedBrace(pattern: glob, index: position)
                }
                let inner = glob[glob.index(after: i)..<endIndex]
                let parts = inner.split(separator: ",", omittingEmptySubsequences: false)
                let escaped = parts.map { NSRegularExpression.escapedPattern(for: String($0)) }
                pattern += "(" + escaped.joined(separator: "|") + ")"
                i = glob.index(after: endIndex)
                continue

            // regex 元字符必须转义
            case ".", "(", ")", "+", "$", "^", "|", "[", "]", "\\":
                pattern.append("\\")
                pattern.append(c)

            default:
                pattern.append(c)
            }

            i = glob.index(after: i)
        }

        pattern += "$"
        // 不传 `caseInsensitive` 选项 → 默认 case-sensitive
        return try NSRegularExpression(pattern: pattern)
    }

    /// 测试给定路径是否完整匹配 regex（必须命中整个字符串）。
    ///
    /// `toRegex` 出来的 pattern 已经带 `^...$` 锚定，所以这里用 `firstMatch` 检查 range 是否覆盖全部。
    public static func matches(_ regex: NSRegularExpression, path: String) -> Bool {
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        return regex.firstMatch(in: path, options: [], range: range) != nil
    }

    /// 批量编译 + 命中检测：常用于 ignore 规则集 / Tier 0/1 glob 列表。
    ///
    /// caller 用法：
    /// ```swift
    /// let regexes = try GlobCompiler.compileAll(TierRules.defaultIgnorePatterns)
    /// // 后续命中检测
    /// if GlobCompiler.matchesAny(regexes, path: "src/index.ts") { /* ignore */ }
    /// ```
    public static func compileAll(_ globs: [String]) throws -> [NSRegularExpression] {
        try globs.map { try toRegex($0) }
    }

    public static func matchesAny(_ regexes: [NSRegularExpression], path: String) -> Bool {
        for regex in regexes where matches(regex, path: path) {
            return true
        }
        return false
    }
}
