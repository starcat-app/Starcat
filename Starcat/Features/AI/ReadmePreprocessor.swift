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
//  - **2026-06-13 dong4j 拍板修订**（推翻 A3 的「保留行内 HTML 标签让 embedding
//    看到结构」决策）：`readmes.content` 的唯一消费者是机器（向量化 / AI 摘要），
//    HTML 标签纯粹是噪声 token；与 `process(html:)` 一刀切行为对齐，让两条路径
//    产出格式一致的纯文本。配套：① 抽 `sanitize(markdown:)` 独立公开方法（只做
//    净化、不截断），让 `ReadmeAPI.refreshMarkdownIfNeeded` 在落库前可以单独调用,
//    `readmes.content` 直接存清洗后的纯文本；② `process(markdown:)` 仍是消费方
//    入口，内部改为 `truncate(sanitize(markdown:))`，对已经 sanitize 过的字符串
//    再调一次是幂等的（标签 0 次匹配 + entity 已解码），可忽略开销。
//  - 截断长度由调用方传入（默认走 `AppSettings.aiReadmeTruncateLength`，
//    Settings UI 滑杆范围 2000-32000）。截断在"清洗之后"做，否则会算上 HTML 标签长度。
//  - HTML / Markdown 两条分支共用最终的"strip 标签 + decode entity + 空白压缩
//    + 截断"流程；唯一差异：HTML 路径用 `\\s+` 合并所有空白成单空格（结构已丢，
//    无需保段落），Markdown 路径**保留换行**（行级 diff `IndexedTextDiff.shouldRebuild`
//    依赖换行切分，否则退化为"整段一行"）。
//  - 输入空字符串直接返回空串，调用方需自行处理"没有 README"的兜底。
//
//  已踩过的坑：
//  - `<script[\\s\\S]*?</script>` 用 `[\\s\\S]` 而不是 `.`，避免 NSRegularExpression
//    默认不跨行匹配导致脚本块漏剔；同样适用于 `<style>`。
//  - `\\s+` 合并空白会把 Markdown 段落分隔 `\n\n` 压成一个空格，导致行级 diff 失真；
//    HTML 路径接受这种损失（已经丢了结构），但 Markdown 路径**保留换行**，
//    否则 `IndexedTextDiff` 退化为 "整段一行"。
//  - **代码块里的 HTML 示例会被误删**：例如用户在 README 写
//    ```html\n<div class="foo">Hello</div>\n```
//    一刀切 `<[^>]+>` 后只剩 "Hello"。**dong4j 决策（2026-06-13）：接受这个损失**——
//    README 中讲 HTML 用法的代码示例不是向量化/AI 摘要的关键信号，主要语义从
//    非代码段提取已经足够；保护代码块的方案（先 stash ``` 围栏内容再 strip 后放回）
//    复杂度过高，先不引入。
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
    /// **2026-06-13 修订**：内部抽出 `sanitize(markdown:)` 单独做净化，本方法
    /// 现在只是 `truncate(sanitize(...))` 的薄封装。两个分工：
    /// - `sanitize`：给"落库前一次性清洗"用（`ReadmeAPI.refreshMarkdownIfNeeded`），
    ///   不知道 / 不应该知道下游的截断长度；
    /// - `process`：给消费方用（`SemanticSearchService` / `RepoAIInsightService`），
    ///   按调用方传入的 `maxLength`（来自 `AppSettings.aiReadmeTruncateLength`）截断。
    ///
    /// 幂等性：对已经 sanitize 过的字符串再调本方法，正则匹配 0 次、entity 已是
    /// 解码形态，等价于 `truncate(原文)`，开销可忽略。
    static func process(markdown: String, maxLength: Int = defaultMaxLength) -> String {
        truncate(sanitize(markdown: markdown), maxLength: maxLength)
    }

    /// 净化原始 Markdown（不截断），用于"落库前一次性清洗"场景。
    ///
    /// 清洗规则（**2026-06-13 dong4j 拍板修订**，推翻 A3 的「保留行内 HTML 标签」决策）：
    /// 1. 删 `<script>` / `<style>` 整段（含内容），避免脚本残骸污染向量；
    /// 2. 删 `<img>` 与 markdown 图片语法 `![alt](url)`，embedding 用不上图像；
    /// 3. **删所有 HTML 标签**（含行内 `<a>` / `<details>` / `<summary>` / 块级
    ///    `<div>` / `<table>` 等）—— 与 `process(html:)` 行为完全对齐；
    /// 4. 解码常见 HTML entity（`&nbsp;` / `&amp;` / `&lt;` / `&gt;` / `&quot;` /
    ///    `&#39;` / `&apos;`），避免字面量 `&amp;` 喂进 embedding 当噪声 token；
    /// 5. 行首尾 trim + 多余空行（≥3 连续空行）压成单空行（保段落界限）+ 整体 trim。
    ///
    /// **不做**的事（明确边界）：
    /// - 不截断（截断由调用方按 `maxLength` 自行决定）；
    /// - 不剔除 shields.io badge 行（A3 决策保留）；
    /// - 不保护代码块里的 HTML 示例（dong4j 拍板接受这个损失，详见文件头注释）；
    /// - 不删 markdown 链接语法 `[text](url)`（链接 text 是有语义的，URL 也提供上下文）。
    ///
    /// 为何保留换行：行级 diff（`IndexedTextDiff.shouldRebuild`）依赖换行切分；
    /// HTML 路径已经丢了换行结构，纯 Markdown 路径必须留住。
    ///
    /// **顺序约束（保幂等性）**：先 `decodeHTMLEntities` **再** `strip HTML 标签`。
    /// 反过来不幂等：原文里如果有 `&lt;tag&gt;`，第一次 strip 时不匹配（是 entity 不是标签），
    /// decode 完后变成字面量 `<tag>`；如果对输出再跑一次 sanitize，第二次 strip 就会把
    /// `<tag>` 误删，破坏幂等性 —— `IndexedTextDiff.shouldRebuild` 看到内容变化会触发
    /// 无谓重建。这个顺序还**符合 dong4j 初衷**：用户写 `&lt;tag&gt;` 表达"字面量 HTML
    /// 标签名"时（如在文档里讲 HTML 用法），strip 后剥离 `<tag>` 是合理的噪声清洗。
    static func sanitize(markdown: String) -> String {
        let decoded = decodeHTMLEntities(markdown)
        let cleaned = decoded
            .replacingOccurrences(of: "<script[\\s\\S]*?</script>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<style[\\s\\S]*?</style>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<img[^>]*>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)

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
        return compacted
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
