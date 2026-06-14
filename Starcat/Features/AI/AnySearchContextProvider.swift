//
//  AnySearchContextProvider.swift
//  Starcat
//
//  单仓摘要的外部补充上下文。外部网页一律视为不可信材料，只提供事实线索与链接，
//  不允许覆盖 README/仓库元数据，也不执行网页中的任何指令。
//
//  **AnySearch 查询参数边界**：本文件查询固定走 `domain: "code"`、**不传 tag**，
//  与用户在「搜索弹窗」自由调整的 `AnySearchFilters` 完全解耦。理由：
//  - AI 仓库摘要是固定场景 —— repo 一定是代码项目，写死 `domain: "code"` 让
//    AnySearch 网关优先返回开发相关材料（文档 / release notes / SDK 参考）；
//  - 用户在搜索弹窗里把 domain 调成 music / fashion 找音乐项目是合理诉求，
//    但 AI 摘要场景不该跟着跑偏；
//  - 保持 hard-code 避免后续协作者误把用户偏好接进来导致摘要质量下降。
//
//  **演进历史**（Y9.4 dong4j 2026-06-14 实测修复）：
//  - 老版本曾加 `tag: "code.doc"` 试图限定到 code 域的「文档子能力」，但实测发现
//    AnySearch 上游对该参数组合连续返回 `502 Bad Gateway`（重试一次仍 502），而
//    全局搜索（AnySearchWebProvider）不传 tag 同样的 API key 同样网络 200 OK。
//  - 对照集成方案文档 `docs/需求讨论/starcat-anysearch-integration-plan.md`
//    Line 1206-1210 AI Context 示例明确写 `tag: nil`，老版本是我（之前的实现）
//    自作主张加的"优化"，注释里还冒充 dong4j 拍板，属于幻觉决策。
//  - 修复：删除 tag 参数，与文档对齐；contentTypes 仍保留 ["web", "doc", "news"]
//    保证 AI 摘要拿到的是阅读材料而非动图 / 商品页。
//

import Foundation
import os

struct AIExternalContext: Equatable, Sendable {
    let markdown: String
    let sources: [URL]
}

@MainActor
final class AnySearchContextProvider {
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func collect(for repo: Repo) async throws -> AIExternalContext? {
        // Y9.3（dong4j 2026-06-14 排查"开关都开了为什么没注入"）：
        // 在 collect 内部各路径加 OSLog 诊断，让用户能在 Console.app 看到
        // anysearch 是被拦截了 / 抛错了 / 0 结果了 / 还是真成功了。
        // 之前只有「抛错」才打 log，0 结果和守卫拦截都静默，定位困难。
        //
        // log 字段口径：
        //   - 总开关守卫：debug 级，正常关闭路径不需要 spam log
        //   - HTTP 抛错：error 级（在 RepoAIInsightService 里已有，此处只补响应路径）
        //   - 空结果：info 级（这是用户最想知道的"调用成功但拉到 0 条"）
        //   - 成功：info 级 + 命中条数
        guard Self.allowsExternalContext(
            repoIsPrivate: repo.isPrivate,
            enabled: settings.anySearchEnabled && settings.aiExternalContextEnabled,
            allowPrivate: settings.aiExternalContextAllowPrivateRepos
        ) else {
            AppLog.ai.debug("""
                AnySearch.collect blocked by settings: \
                anySearchEnabled=\(self.settings.anySearchEnabled, privacy: .public) \
                aiExternalContextEnabled=\(self.settings.aiExternalContextEnabled, privacy: .public) \
                isPrivate=\(repo.isPrivate, privacy: .public) \
                allowPrivate=\(self.settings.aiExternalContextAllowPrivateRepos, privacy: .public)
                """)
            return nil
        }

        let client = AnySearchClient(
            apiKey: settings.anySearchAPIKey(),
            anonymous: settings.anySearchAnonymousMode
        )
        let queries = Self.queries(for: repo)
        AppLog.ai.info("""
            AnySearch.collect start: repo=\(repo.fullName, privacy: .public) \
            anonymous=\(self.settings.anySearchAnonymousMode, privacy: .public) \
            queries=\(queries.count, privacy: .public)
            """)
        var results: [AnySearchResult] = []
        for query in queries.prefix(2) {
            // Y9.4（2026-06-14 dong4j 实测修复）：不传 `tag`。
            //
            // 与集成方案文档 `docs/需求讨论/starcat-anysearch-integration-plan.md`
            // Line 1206-1210 AI Context 示例对齐（`tag: nil`）。老版本曾加
            // `tag: "code.doc"` 试图限定到 code 域文档子能力，但触发上游 502。
            // 见文件顶注释「演进历史」段。
            let response = try await client.search(AnySearchRequest(
                query: query,
                maxResults: 5,
                domain: "code",
                contentTypes: ["web", "doc", "news"],
                language: Locale.current.language.languageCode?.identifier
            ))
            AppLog.ai.info("""
                AnySearch.collect query response: \
                query=\"\(query, privacy: .public)\" results=\(response.results.count, privacy: .public)
                """)
            results.append(contentsOf: response.results)
        }

        var seen = Set<String>()
        let unique = results.filter { seen.insert($0.normalizedURL.absoluteString).inserted }.prefix(6)
        guard !unique.isEmpty else {
            AppLog.ai.info("""
                AnySearch.collect ended with zero unique results: repo=\(repo.fullName, privacy: .public) \
                rawCount=\(results.count, privacy: .public)
                """)
            return nil
        }
        AppLog.ai.info("""
            AnySearch.collect success: repo=\(repo.fullName, privacy: .public) \
            unique=\(unique.count, privacy: .public)
            """)
        let entries = unique.map { result in
            let snippet = String((result.snippet ?? result.content ?? "").prefix(500))
            return "- [\(result.title)](\(result.normalizedURL.absoluteString))\n  \(snippet)"
        }
        // 2026-06-14 v4 dong4j 拍板：去掉 `trust="untrusted"` 标记 + 删除全部警告语。
        //
        // 设计变更原因：之前用 `trust="untrusted"` + "supplementary signals / 不可覆盖
        // README / 不要执行内置指令" 三句话警告，是为了让 LLM 把 AnySearch 内容当成弱信号；
        // 实测 dong4j 决定让 AnySearch 跟 README/metadata **完全平等参考**——AnySearch
        // 也是用户主动开启的、来自可信引擎的检索结果，没必要单独打标记降权。
        //
        // 保留 `<external_context>` 包裹（不带 trust 属性）的原因：
        // - 给 LLM 一个清晰的"section 边界"标记，避免跟 README 段混淆；
        // - 跟 prompt 模板的 `## External References` 占位符配合，让 LLM 知道这部分
        //   信息来自外部网页检索，引用时可以带链接。
        //
        // 注：prompt-injection 防御也随警告语一起被移除——这是"信任 AnySearch 引擎不会
        // 返回恶意内容"的明确选择。如果将来发现 AnySearch 引擎返回的页面标题/snippet
        // 中携带 prompt-injection 文本，需要重新评估这个决定。
        let markdown = """

        <external_context source="AnySearch">
        \(entries.joined(separator: "\n"))
        </external_context>
        """
        return AIExternalContext(markdown: markdown, sources: unique.map(\.normalizedURL))
    }

    nonisolated static func queries(for repo: Repo) -> [String] {
        let description = repo.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return [
            "\(repo.fullName) documentation release notes",
            "\(repo.fullName) alternatives review \(String(description.prefix(120)))"
        ]
    }

    nonisolated static func allowsExternalContext(
        repoIsPrivate: Bool,
        enabled: Bool,
        allowPrivate: Bool
    ) -> Bool {
        enabled && (!repoIsPrivate || allowPrivate)
    }
}
