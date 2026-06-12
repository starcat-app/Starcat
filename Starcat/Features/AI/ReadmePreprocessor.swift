//
//  ReadmePreprocessor.swift
//  Starcat
//
//  README 清洗与截断工具（详见 `docs/详细设计/26-向量搜索改进.md`，决策 A3）。
//
//  模块职责：
//  - 把 README（HTML 或原始 Markdown）清洗成 AI / embedding 可读的纯文本；
//  - 提供单一入口给 `RepoAIInsightService.makeSource` 与 `IndexedTextBuilder` 共用，
//    避免出现"两份噪声清洗逻辑、行为不一致"的回归（dong4j 2026-06-12 反馈：
//    AI 摘要生成前的 readme html 处理逻辑可以抽离出来，向量化和 ai 摘要这两个地方都可以用）。
//
//  关键约束：
//  - 决策 A3：当前只做"简单清洗 + 字符截断"，**不**做章节黑白名单 / Badge 行剔除。
//    上线后若评估发现 README 噪声仍然显著（多数 README 头部塞 30+ shields.io
//    badge），再升级 A2。
//  - 截断长度由调用方传入（默认走 `AppSettings.aiReadmeTruncateLength`，
//    Settings UI 滑杆范围 2000-32000）。截断在"清洗之后"做，否则会算上 HTML 标签长度。
//  - HTML / Markdown 两条分支共用最终的"压缩空白 + 截断"流程，差异只在"剥 HTML 标签"。
//  - 输入空字符串直接返回空串，调用方需自行处理"没有 README"的兜底。
//
//  已踩过的坑：
//  - `<script[\\s\\S]*?</script>` 用 `[\\s\\S]` 而不是 `.`，避免 NSRegularExpression
//    默认不跨行匹配导致脚本块漏剔；同样适用于 `<style>`。
//  - `\\s+` 合并空白会把 Markdown 段落分隔 `\n\n` 压成一个空格，导致行级 diff 失真；
//    HTML 路径接受这种损失（已经丢了结构），但 Markdown 路径**保留换行**，
//    否则 `IndexedTextDiff` 退化为 "整段一行"。
//

import Foundation

enum ReadmePreprocessor {

    /// 默认截断长度（与 `AppSettings.aiReadmeTruncateLength` 的 `defaultValue` 对齐）。
    /// 不直接 `import AppSettings` 是为了让本工具保持纯函数、可独立单测。
    static let defaultMaxLength: Int = 12_000

    /// 清洗 GitHub 渲染好的 README HTML（来自 `/repos/:owner/:repo/readme` 的
    /// `application/vnd.github.html` 响应）。
    ///
    /// 清洗规则（A3）：
    /// 1. 删 `<script>` / `<style>` 整段（含内容）；
    /// 2. 删 `<img>`（embedding 用不上图像，文本残骸只会污染向量）；
    /// 3. 删所有 HTML 标签（保留文本节点）；
    /// 4. 解码常见 HTML entity（`&nbsp;` / `&amp;` / `&lt;` / `&gt;` / `&quot;` / `&#39;`）；
    /// 5. 合并连续空白为单个空格、首尾 trim；
    /// 6. 长度截断（默认 12000，可配置）。
    static func process(html: String, maxLength: Int = defaultMaxLength) -> String {
        let cleaned = html
            .replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<img[^>]*>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let decoded = decodeHTMLEntities(cleaned)
        let collapsed = decoded
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return truncate(collapsed, maxLength: maxLength)
    }

    /// 清洗原始 Markdown 文本（来自 `/repos/:owner/:repo/readme` 的
    /// `application/vnd.github.raw` 响应）。
    ///
    /// 清洗规则（A3）：
    /// 1. 删图片语法 `![alt](url)` 与 HTML `<img>`；
    /// 2. 删 `<script>` / `<style>`（部分 Markdown 文件内嵌 HTML）；
    /// 3. **保留**普通行内 HTML 标签、链接语法、代码围栏 —— 不再深加工，
    ///    让 embedding 模型自己看到结构；
    /// 4. 多余空白行（≥3 连续空行）压成两行（保段落界限）；
    /// 5. 行首尾 trim、整体 trim；
    /// 6. 长度截断。
    ///
    /// 为何保留换行：行级 diff（`IndexedTextDiff.shouldRebuild`）依赖换行切分；
    /// HTML 路径已经丢了换行结构，纯 Markdown 路径必须留住。
    static func process(markdown: String, maxLength: Int = defaultMaxLength) -> String {
        let cleaned = markdown
            .replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<img[^>]*>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: " ", options: .regularExpression)

        // 行内 trim + 段落压缩（保留单个空行作为段落分隔）。
        let lines = cleaned.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var compacted: [String] = []
        var blankRun = 0
        for line in lines {
            if line.isEmpty {
                blankRun += 1
                if blankRun <= 1 { compacted.append("") }
            } else {
                blankRun = 0
                compacted.append(line)
            }
        }
        let normalized = compacted
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return truncate(normalized, maxLength: maxLength)
    }

    // MARK: - Helpers

    private static func truncate(_ text: String, maxLength: Int) -> String {
        guard maxLength > 0 else { return "" }
        if text.count <= maxLength { return text }
        return String(text.prefix(maxLength))
    }

    /// 解码常见 HTML entity；不引入完整 entity 表（实测 GitHub 渲染的 README 这几个就够）。
    private static func decodeHTMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}
