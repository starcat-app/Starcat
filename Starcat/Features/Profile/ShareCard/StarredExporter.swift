//
//  StarredExporter.swift
//  Starcat
//
//  HOM-174：把本地 starred repo 列表导出为 Markdown / HTML 单文件的协调层。
//
//  职责：
//  - 拉取 `[Repo]`（调用方提供，避免本工具绑死 Repository 类型）
//  - 调相应 renderer 拼字符串
//  - 走 NSSavePanel 让用户选保存位置，落盘
//
//  与 `ShareCardExporter`（保存卡片图 / 分享到 X）平行：两者都是"分享卡 sheet 下的一条出口路径"，
//  内部各自独立无依赖，避免一个文件膨胀到难以维护。
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
    /// 1. 渲染：format → 选 renderer → 拼字符串
    /// 2. 弹 NSSavePanel：默认文件名按 `StarredExportFormat.defaultFileName(userLogin:)`
    /// 3. 写文件（UTF-8）；写入失败 / 用户取消时返回 nil
    ///
    /// - Parameters:
    ///   - repos: 已 star 的 repos（调用方负责过滤 isStarred）
    ///   - user: 当前登录用户，用于文档头部 hero 段
    ///   - format: 输出格式
    /// - Returns: 写入成功的 URL；用户取消、渲染为空、写入失败均返回 nil
    static func export(repos: [Repo], user: GitHubUserDTO, format: StarredExportFormat) -> URL? {
        // 1. 渲染
        let body: String
        switch format {
        case .markdown:
            body = StarredMarkdownRenderer.render(repos: repos, user: user)
        case .html:
            body = StarredHTMLRenderer.render(repos: repos, user: user)
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
