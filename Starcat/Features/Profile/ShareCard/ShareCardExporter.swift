//
//  ShareCardExporter.swift
//  Starcat
//
//  HOM-173 用户分享卡片：导出工具。
//  统一封装"渲染 ShareCardContent → PNG → 落盘 / 复制到剪贴板 / 打开 X"三条出口路径，
//  让 `ShareCardSheet` 只做按钮调度，不掺杂 ImageRenderer / NSSavePanel / NSWorkspace 细节。
//
//  三条出口路径：
//
//  1. **保存为图片**（saveImage）：
//     - 用 `ImageRenderer` 渲染 ShareCardContent 为 NSImage（@3x → 1200×1680 PNG）
//     - 弹 `NSSavePanel` 让用户选目录与文件名
//     - 写入 PNG，返回 URL 给调用方做 toast / Finder reveal
//
//  2. **分享到 X**（shareToX）：
//     - 渲染同一张图 → 写到 NSPasteboard（图片+文本）
//     - 打开 `https://x.com/intent/post?text=…` 推文撰写页
//     - 用户在浏览器里 Cmd+V 把图粘到推文里（设计图直接说明这点："把图片粘贴到推文里"）
//     - 不走 X API（需要 OAuth + Bearer token；纯客户端无服务端难以实现），剪贴板 + 浏览器
//       是当前最稳的妥协，也是 Twitter/X Web 长期支持的标准链路
//
//  3. **复制到剪贴板**（copyToPasteboard，本次不绑按钮，留作 share 路径的内部复用）：
//     - 把渲染好的 NSImage 写到通用 NSPasteboard（让用户在任何地方 Cmd+V 粘贴）
//
//  设计权衡：
//  - 没用 NSSharingServicePicker（系统分享弹窗）：在 macOS 14+ 上"分享到第三方"
//    依赖 App Extension 注册，X 没有官方 macOS 分享扩展；Web Intent 是更可靠的兜底。
//  - 没把渲染抽成 actor / Service：渲染本身是同步的（`ImageRenderer` 主线程同步绘制），
//    一次只跑一次（用户点按钮触发）；过度抽象反而增加复杂度。
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 分享卡导出工具。一组静态方法即可，无状态。
@MainActor
enum ShareCardExporter {

    // MARK: - 公开 API

    /// 渲染分享卡为 NSImage（@3x 分辨率，1200×1680 像素）。
    /// 调用方决定后续：写文件 / 写剪贴板 / 直接展示。
    ///
    /// - Parameter content: `ShareCardContent` 视图（外部已配置好 user/theme/contribution）。
    /// - Returns: 渲染好的 NSImage；失败（极少见，比如 Renderer 拿不到 cgImage）返回 nil。
    static func renderImage(content: ShareCardContent) -> NSImage? {
        // ImageRenderer 是 SwiftUI 5（macOS 14+）的标准 view → image 路径
        // scale=3 让导出图达到 1200×1680，足够小红书 / X 的高清需求；
        // 高于 3x 文件体积涨快但视觉收益边际递减
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3.0
        // proposedSize 显式给出，避免 ImageRenderer 在某些场景下使用 0×0 默认值
        renderer.proposedSize = ProposedViewSize(
            width: ShareCardContent.canvasWidth,
            height: ShareCardContent.canvasHeight
        )

        guard let nsImage = renderer.nsImage else {
            AppLog.ui.error("ShareCardExporter: ImageRenderer.nsImage returned nil")
            return nil
        }
        return nsImage
    }

    /// 弹出"保存为图片"对话框；用户选定路径后写 PNG。
    ///
    /// - Parameters:
    ///   - content: 待渲染的卡片视图。
    ///   - userLogin: 用户登录名，用于建议文件名（`{login}-card.png`）。
    /// - Returns: 写入成功的 URL；用户取消或写入失败返回 nil。
    static func saveImage(content: ShareCardContent,
                          userLogin: String) -> URL? {
        guard let nsImage = renderImage(content: content) else { return nil }
        guard let pngData = pngData(from: nsImage) else {
            AppLog.ui.error("ShareCardExporter: failed to encode NSImage as PNG")
            return nil
        }

        let panel = NSSavePanel()
        panel.title = String.l10n("sharecard.savePanel.title")
        panel.message = String.l10n("sharecard.savePanel.message")
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(userLogin)-card.png"
        panel.isExtensionHidden = false

        // runModal() 阻塞当前 runloop 等用户选择；Sheet 在主窗口上层不会冲突
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            return nil
        }

        do {
            try pngData.write(to: url, options: .atomic)
            AppLog.ui.info("ShareCard saved: \(url.path, privacy: .public)")
            return url
        } catch {
            AppLog.ui.error("ShareCard save failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 把渲染图复制到通用 NSPasteboard（系统剪贴板）。
    /// 复制成功后剪贴板里同时有 PNG 数据 + tiff fallback，方便用户 Cmd+V 粘贴到任何地方。
    ///
    /// - Returns: 成功复制返回 true；渲染失败返回 false。
    @discardableResult
    static func copyToPasteboard(content: ShareCardContent) -> Bool {
        guard let nsImage = renderImage(content: content),
              let pngData = pngData(from: nsImage) else {
            return false
        }
        let pasteboard = NSPasteboard.general
        // clearContents() 必调，否则旧内容残留导致接收方拿到错的类型
        pasteboard.clearContents()
        // 写两种类型：① PNG（多数现代 App 优先识别）② TIFF（NSImage 的 native 格式，
        // 老程序 / 系统服务兜底）
        pasteboard.setData(pngData, forType: .png)
        if let tiff = nsImage.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
        AppLog.ui.info("ShareCard copied to pasteboard")
        return true
    }

    /// 分享到 X：图片复制到剪贴板 + 打开 X.com 推文撰写页。
    ///
    /// 用户在 X 网页 / X for macOS 里 Cmd+V 粘贴图片即可发推。设计图明确写"把图片粘贴到推文里"，
    /// 这是 X 没有公开图片直传 URL Scheme 的折中——也是绝大多数桌面浏览器分享插件的标准做法。
    ///
    /// - Parameters:
    ///   - content: 待渲染的卡片视图。
    ///   - userLogin: 用户登录名，用于推文默认正文。
    /// - Returns: 是否成功（剪贴板 + 浏览器都打开成功）。
    @discardableResult
    static func shareToX(content: ShareCardContent, userLogin: String) -> Bool {
        // 先确保剪贴板里有图——失败就直接放弃，不打开 X 页面，避免用户开了页面发现没图
        guard copyToPasteboard(content: content) else { return false }

        // X.com Web Intent：query 里只能带 text，图片必须用户手动粘贴（X 无公开图片直传接口）
        // text 跟随 LocaleStore 决定中英文模板（中文用户看到中文推文）；
        // 不带 url 参数避免 X 自动展开为卡片链接遮住用户的图
        let text = String.l10n("sharecard.shareToX.tweetText")
        var components = URLComponents(string: "https://x.com/intent/post")
        components?.queryItems = [URLQueryItem(name: "text", value: text)]

        guard let url = components?.url else {
            AppLog.ui.error("ShareCardExporter: failed to build X intent URL")
            return false
        }
        // openURL 主线程同步即可——SwiftUI 的 environment(\.openURL) 也行，
        // 但本工具没有 View 上下文，直接用 NSWorkspace 是最不依赖外部状态的写法
        let opened = NSWorkspace.shared.open(url)
        if !opened {
            AppLog.ui.error("ShareCardExporter: NSWorkspace.open(\(url.absoluteString, privacy: .public)) returned false")
        }
        // 即使 NSWorkspace.open 返回 false，剪贴板也已经写好；用户可以手工去 X 粘贴。
        // 所以仍然返回 true（部分降级）。
        _ = userLogin  // 保留参数，未来想在 tweet 模板里嵌 @login 时无需改签名
        return true
    }

    // MARK: - 内部工具

    /// NSImage → PNG Data。
    /// NSImage 内部是 TIFF/CGImage 表示；导出 PNG 需要走 NSBitmapImageRep。
    /// 失败可能在：① 无 cgImage（极少见）② representation(using:.png) 返回 nil（编码失败）
    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
