//
//  StarredExporter.swift
//  Starcat
//
//  HOM-174：把本地 starred repo 列表导出为 Markdown / HTML 单文件的协调层。
//
//  职责：
//  - 拉取 `[Repo]`（调用方提供，避免本工具绑死 Repository 类型）
//  - HTML 导出时额外拉 AI 摘要 / 用户标签 / 用户头像 base64，喂给 HTML renderer 的 supplements
//  - 调相应 renderer 拼字符串
//  - 走 NSSavePanel 让用户选保存位置，落盘
//
//  与 `ShareCardExporter`（保存卡片图 / 分享到 X）平行：两者都是"分享卡 sheet 下的一条出口路径"，
//  内部各自独立无依赖，避免一个文件膨胀到难以维护。
//
//  v2（dong4j 2026-06-06）：
//  - HTML 导出新增 supplements 数据采集：AI 摘要、用户标签、头像 base64。
//  - Markdown 路径保持原样（用户当前只关心 HTML 模板优化）。
//  - 头像下载走 URLSession 单次 GET，失败 / 超时 / 非图片 MIME 一律静默退化为 nil（HTML 端兜底用 initials）。
//

import Foundation
import AppKit
import UniformTypeIdentifiers

/// Starred 列表导出协调器。无状态，一组静态方法即可。
@MainActor
enum StarredExporter {

    /// 导出 starred 列表为指定格式的单文件。
    ///
    /// 流程：
    /// 1. **HTML 专属**：并发拉 AI 摘要 / 标签 / 头像 base64，组装 supplements
    /// 2. 渲染：format → 选 renderer → 拼字符串
    /// 3. 弹 NSSavePanel：默认文件名按 `StarredExportFormat.defaultFileName(userLogin:)`
    /// 4. 写文件（UTF-8）；写入失败 / 用户取消时返回 nil
    ///
    /// - Parameters:
    ///   - repos: 已 star 的 repos（调用方负责过滤 isStarred）
    ///   - user: 当前登录用户，用于文档头部 hero 段
    ///   - format: 输出格式
    ///   - dependencies: 用于拉 AI 摘要 / 标签 / 头像（HTML 路径需要）。
    ///     nil 时跳过 supplements（适用于 markdown 或脱离 app 上下文的测试场景）。
    /// - Returns: 写入成功的 URL；用户取消、渲染为空、写入失败均返回 nil
    static func export(
        repos: [Repo],
        user: GitHubUserDTO,
        format: StarredExportFormat,
        dependencies: AppDependencies? = nil
    ) async -> URL? {
        // 1. 渲染
        let body: String
        switch format {
        case .markdown:
            body = StarredMarkdownRenderer.render(repos: repos, user: user)
        case .html:
            let supplements: StarredHTMLRenderer.ExportSupplements
            if let dependencies {
                supplements = await collectSupplements(repos: repos, user: user, dependencies: dependencies)
            } else {
                supplements = .empty
            }
            body = StarredHTMLRenderer.render(
                repos: repos,
                user: user,
                supplements: supplements
            )
        }

        guard !body.isEmpty else {
            AppLog.ui.error("StarredExporter: rendered \(format.displayName, privacy: .public) body is empty")
            return nil
        }

        // 2. 弹保存面板
        let panel = NSSavePanel()
        panel.title = String(localized: "sharecard.exportStarred.savePanel.title")
        panel.message = String(localized: "sharecard.exportStarred.savePanel.message")
        panel.allowedContentTypes = allowedContentTypes(for: format)
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = format.defaultFileName(userLogin: user.login)
        panel.isExtensionHidden = false

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            return nil
        }

        // 3. 落盘
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            AppLog.ui.info("Exported starred (\(format.displayName, privacy: .public)) -> \(url.path, privacy: .public)")
            return url
        } catch {
            AppLog.ui.error("StarredExporter write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Supplements 收集（HTML 专属）

    /// 并发拉 AI 摘要 / 标签 / 用户头像 / repo owner 头像，组装 `ExportSupplements`。
    /// 任一数据源失败都不阻断导出——supplements 各字段独立可选，缺哪个 HTML 端就 fallback 哪个。
    ///
    /// v3（dong4j 2026-06-06）：头像加载改走 `AvatarCacheLoader`——先查 Kingfisher 磁盘 cache
    /// （命中即 base64 编码，零网络），未命中再走 URLSession 兜底，下载后顺手写回 cache。
    /// 同时新增 owner 头像批量加载（去重 + 并发限 8）作为 repo 卡片的 logo。
    private static func collectSupplements(
        repos: [Repo],
        user: GitHubUserDTO,
        dependencies: AppDependencies
    ) async -> StarredHTMLRenderer.ExportSupplements {
        // 收集去重后的 owner 集合，作为 owner 头像加载的输入
        let ownerSet = Set(repos.map(\.owner))

        // 四个独立 async 任务并发跑：
        // ① AI 摘要批量取 ② 标签批量取 ③ 用户头像（cache 优先）④ owner 头像（cache 优先 + 并发限 8）
        async let aiRecordsTask = (try? await dependencies.aiSummaryRepository.fetchLatestPerRepo()) ?? [:]
        async let tagAssignmentsTask = (try? await dependencies.repoTagRepository.fetchAllTagAssignments()) ?? [:]
        async let avatarTask = AvatarCacheLoader.loadAsDataURI(urlString: user.avatarUrl)
        async let ownerAvatarsTask = AvatarCacheLoader.loadOwnerAvatars(owners: ownerSet)

        let aiRecords = await aiRecordsTask
        let tagAssignments = await tagAssignmentsTask
        let avatarDataURI = await avatarTask
        let ownerAvatars = await ownerAvatarsTask

        // 从 AI 摘要 JSON 里取 markdown 文本（兼容旧记录用 summary 字段，新记录用 summaryMarkdown）。
        // 解析失败 / 字段全空都视作"该 repo 无可展示的 markdown 摘要"。
        var aiSummaries: [Int64: String] = [:]
        aiSummaries.reserveCapacity(aiRecords.count)
        for (repoId, record) in aiRecords {
            if let markdown = extractMarkdown(fromSummaryJSON: record.summaryJson),
               !markdown.isEmpty {
                aiSummaries[repoId] = markdown
            }
        }

        // tag 关联：Tag 对象 → 仅 name（HTML 不需要 id / color / sort_order 这些细节）。
        var repoTags: [Int64: [String]] = [:]
        repoTags.reserveCapacity(tagAssignments.count)
        for (repoId, tags) in tagAssignments {
            repoTags[repoId] = tags.map(\.name)
        }

        return StarredHTMLRenderer.ExportSupplements(
            aiSummaries: aiSummaries,
            repoTags: repoTags,
            avatarDataURI: avatarDataURI,
            ownerAvatars: ownerAvatars
        )
    }

    /// 从 `AISummaryRecord.summaryJson` 解出可展示的 markdown 文本。
    /// 优先级：summaryMarkdown → summary。两者都空返回 nil。
    nonisolated private static func extractMarkdown(fromSummaryJSON json: String) -> String? {
        guard let data = json.data(using: .utf8) else { return nil }
        struct Probe: Decodable {
            let summary: String?
            let summaryMarkdown: String?
        }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else { return nil }
        if let md = probe.summaryMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines), !md.isEmpty {
            return md
        }
        if let s = probe.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return s
        }
        return nil
    }

    // 头像下载逻辑已迁移到 `AvatarCacheLoader`（cache 优先 + URLSession 兜底 + 写回 cache）。
    // 见 `AvatarCacheLoader.loadAsDataURI(urlString:)` 与 `loadOwnerAvatars(owners:)`。

    // MARK: - helpers

    /// 给 NSSavePanel 设的 allowedContentTypes。
    /// UTType.markdown 在 macOS 14+ 是系统内建；HTML 走 UTType.html。
    /// 用 UTType 而非自定义扩展名让 Finder 识别图标更稳定。
    private static func allowedContentTypes(for format: StarredExportFormat) -> [UTType] {
        switch format {
        case .markdown:
            // .text fallback：极少数老系统 `UTType("public.markdown")` 可能 nil
            return [UTType("net.daringfireball.markdown") ?? .plainText, .plainText]
        case .html:
            return [.html]
        }
    }
}
