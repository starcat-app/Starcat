//
//  StarredExportFormat.swift
//  Starcat
//
//  HOM-174：Starred 列表导出格式枚举。
//
//  存在意义：让 `ShareCardSheet` 的 Menu 按钮、`StarredExporter` 落盘逻辑、
//  以及测试代码共享同一份 case 列表，避免散点字符串硬编码。
//

import Foundation

/// Starred 列表导出格式。
/// 当前支持 Markdown 单文件、HTML 单页面两种形态——都是"打开就能看，不依赖额外工具"的产物，
/// 便于用户存档 / 上传到 Gist / 上传到自己的博客。
enum StarredExportFormat {
    case markdown
    case html

    /// 文件后缀（不含点）。
    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .html: return "html"
        }
    }

    /// 默认保存文件名（不含路径）。
    /// 命名规范：`starcat-{login}-starred-{yyyyMMdd}.{ext}`；卡片图导出为 `{login}-card.png`。
    func defaultFileName(userLogin: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        return "starcat-\(userLogin)-starred-\(stamp).\(fileExtension)"
    }

    /// 显示名（用于反馈文案、log）。
    var displayName: String {
        switch self {
        case .markdown: return "Markdown"
        case .html: return "HTML"
        }
    }
}
