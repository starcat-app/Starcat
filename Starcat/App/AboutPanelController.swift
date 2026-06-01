//
//  AboutPanelController.swift
//  Starcat
//
//  macOS 原生关于窗口控制器。
//
//  使用 NSApplication.shared.orderFrontStandardAboutPanel(options:) 唤起系统关于面板，
//  通过 NSApplication.AboutPanelOptionKey.credits 设置自定义致谢内容。
//

import AppKit

/// 关于面板控制器
final class AboutPanelController {

    /// 显示关于面板
    static func show() {
        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Starcat",
            .applicationVersion: versionString,
            .credits: creditsAttributedString,
            .version: buildString
        ]

        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 版本字符串
    private static var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        return "Version \(version)"
    }

    /// Build 字符串
    private static var buildString: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Build \(build)"
    }

    /// Credits 富文本（用于关于面板的 Credits 标签页）
    private static var creditsAttributedString: NSAttributedString {
        let credits = """
        Acknowledgements

        This application makes use of the following third party libraries:

        Alamofire
        Copyright (c) 2014 Alamofire Software Foundation
        MIT License
        https://github.com/Alamofire/Alamofire

        GRDB.swift
        Copyright (c) 2015-2024 Gwendal Rouard
        MIT License
        https://github.com/groue/GRDB.swift

        Kingfisher
        Copyright (c) 2019 Wei Wang
        MIT License
        https://github.com/onevcat/Kingfisher

        Swift Markdown
        Copyright (c) 2014-2026 Ordered Software
        MIT License
        https://github.com/gonzalezreal/swift-markdown

        Thank you to all the open source contributors!
        """

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacing = 8
        paragraphStyle.lineSpacing = 4

        let fontSize: CGFloat = 13
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: fontSize + 2),
            .paragraphStyle: paragraphStyle
        ]

        let normalAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .paragraphStyle: paragraphStyle
        ]

        let smallAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize - 2),
            .paragraphStyle: paragraphStyle,
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        let result = NSMutableAttributedString()

        // Title
        result.append(NSAttributedString(string: "Acknowledgements\n\n", attributes: titleAttributes))

        // Subtitle
        result.append(NSAttributedString(string: "This application makes use of the following third party libraries:\n\n", attributes: normalAttributes))

        // Alamofire
        result.append(NSAttributedString(string: "Alamofire\n", attributes: titleAttributes))
        result.append(NSAttributedString(string: "Copyright (c) 2014 Alamofire Software Foundation\nMIT License\nhttps://github.com/Alamofire/Alamofire\n\n", attributes: smallAttributes))

        // GRDB
        result.append(NSAttributedString(string: "GRDB.swift\n", attributes: titleAttributes))
        result.append(NSAttributedString(string: "Copyright (c) 2015-2024 Gwendal Rouard\nMIT License\nhttps://github.com/groue/GRDB.swift\n\n", attributes: smallAttributes))

        // Kingfisher
        result.append(NSAttributedString(string: "Kingfisher\n", attributes: titleAttributes))
        result.append(NSAttributedString(string: "Copyright (c) 2019 Wei Wang\nMIT License\nhttps://github.com/onevcat/Kingfisher\n\n", attributes: smallAttributes))

        // Markdown
        result.append(NSAttributedString(string: "Swift Markdown\n", attributes: titleAttributes))
        result.append(NSAttributedString(string: "Copyright (c) 2014-2026 Ordered Software\nMIT License\nhttps://github.com/gonzalezreal/swift-markdown\n\n", attributes: smallAttributes))

        // Thank you
        result.append(NSAttributedString(string: "Thank you to all the open source contributors!", attributes: normalAttributes))

        return result
    }
}
