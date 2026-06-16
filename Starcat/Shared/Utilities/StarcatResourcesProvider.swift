//
//  StarcatResourcesProvider.swift
//  Starcat
//
//  把"当前对话所属 repo 的 Starcat 衍生资源"（外部 Wiki 镜像、本地 CodeFlow 调用图）
//  拼成 markdown 块字符串，作为 AI Chat system prompt 的 `{starcatResources}` 占位符值。
//
//  关键设计（dong4j 2026-06-15 拍板）：
//
//  1. **独立 section `## Starcat Resources`**（与 `## Runtime Context` 并列）：
//     - 不与运行环境、仓库元数据混在一起，让 AI 一眼能区分"Starcat 系统能提供的额外
//       资源"与"通用上下文信息"；
//     - 全空时本 provider 返回空字符串，chat template 里的空 section header 会让 LLM
//       自动忽略，无副作用（与 `{aiUserContext}` 等空 section 同款行为）。
//
//  2. **Wiki 来源名硬编码英文**（"DeepWiki" / "ZRead" / "CodeWiki"），不用
//     `WikiSource.displayName`：
//     - displayName 走 `String.l10n(...)`，会按 locale 翻译成 "深维基" 等；
//     - chat system prompt 整段是英文，混 zh-Hans 翻译破坏 LLM 解析一致性；
//     - 与 `RuntimeContextProvider` 硬编码英文 weekday 同款决策。
//
//  3. **CodeFlow 用裸 `file://` URL**（dong4j 拍板形态 E1）：
//     - LLM 把 URL 转 markdown 链接 `[CodeFlow](file:///...)`，浏览器渲染时
//       系统自动用默认浏览器打开本地 HTML；
//     - 已知缺点：URL 含用户名（`/Users/<login>/...`），属于轻度信息暴露；
//       项目自部署 LLM / BYOK 场景下用户已知风险，dong4j 拍板可接受。
//
//  4. **写一段简短 AI 使用指引**（"When asked about documentation ... recommend the
//     relevant link"）：避免 LLM 拿到链接后不知道用，或反过来在无链接时编造一个。
//     指引和链接共生 —— 二者都存在时才输出；全空时连指引也不输出。
//
//  5. **静态函数 + 纯数据入参**：与 `RuntimeContextProvider` 同款。测试 deterministic
//     直接构造 `[WikiLink]` / `URL` 入参即可，无需测试注入点。
//

import Foundation

/// AI Chat system prompt 注入的「Starcat 资源」占位符生成器。
enum StarcatResourcesProvider {

    /// 把 wiki 链接 + CodeFlow 页面 URL 拼成 markdown 块字符串。
    ///
    /// - Parameters:
    ///   - wikiLinks: 调用方已经从 `WikiContextService.cachedLinks(...)` 拿到的
    ///     已索引 wiki 链接列表。允许空；顺序由调用方保证（一般已按
    ///     `WikiSource.sortOrder` 排序）。
    ///   - codeFlowPageURL: 本地 CodeFlow 工件的 `file://` URL。nil = 没生成过 /
    ///     被删了。
    /// - Returns: 渲染好的 markdown 块字符串。完全无资源时返回**空串**（让
    ///   chat template 的空 section header 自然被 LLM 忽略）。
    nonisolated static func snapshot(
        wikiLinks: [WikiLink],
        codeFlowPageURL: URL?
    ) -> String {
        let hasWikis = !wikiLinks.isEmpty
        let hasCodeFlow = codeFlowPageURL != nil
        if !hasWikis && !hasCodeFlow {
            return ""
        }

        var blocks: [String] = []

        if hasWikis {
            var lines: [String] = []
            lines.append("External wiki indexes for this repository (third-party documentation mirrors):")
            for link in wikiLinks {
                let name = englishName(for: link.source)
                lines.append("- \(name): \(link.url.absoluteString)")
            }
            blocks.append(lines.joined(separator: "\n"))
        }

        if let codeFlowPageURL {
            var lines: [String] = []
            lines.append("Local CodeFlow visualization for this repository (interactive call-graph HTML, opens in browser):")
            lines.append("- \(codeFlowPageURL.absoluteString)")
            blocks.append(lines.joined(separator: "\n"))
        }

        blocks.append(
            "When the user asks about documentation, architecture, code structure, or call relationships, recommend the relevant link(s) above instead of guessing URLs. Only recommend links that are explicitly listed."
        )

        return blocks.joined(separator: "\n\n")
    }

    // MARK: - Private helpers

    /// `WikiSource` → AI prompt 用的英文官方名。
    ///
    /// 服务端新增源时**必须**同步更新这里，否则会落回 `unknown` 的 raw value（哪怕
    /// raw value 看着也是英文，也比不上官方拼写规范）。
    private static func englishName(for source: WikiSource) -> String {
        switch source {
        case .deepWiki: return "DeepWiki"
        case .zread: return "ZRead"
        case .codeWiki: return "CodeWiki"
        case .unknown(let raw): return raw
        }
    }
}
