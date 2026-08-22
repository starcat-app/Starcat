//
//  GitHubUserAttachment.swift
//  Starcat
//
//  GitHub Issue 评论框粘贴图片的本地契约。
//
//  为什么单独抽这一层：
//  - 官方 REST 没有「上传评论图片」端点；网页粘贴走未文档化的
//    `POST uploads.github.com/user-attachments/assets`，成功后再把 URL 写进 Markdown。
//  - 评论 API 仍然只收 `{ body }`。预览和发出去的正文必须是同一套 `![alt](url)`，
//    不能在撰写态塞附件、预览态另开渲染通道。
//  - URL / JSON / 光标插入都是纯函数，单测不打网络、不碰 NSTextView。
//

import AppKit
import Foundation

/// 未文档化上传通道的解析错误。网络层 4xx/5xx 仍走 `NetworkError`。
enum GitHubUserAttachmentError: Error, Equatable {
    case missingAssetURL
    case emptyImage
    case imageTooLarge
    case missingRepositoryID
}

/// 上传 URL、响应解析、Markdown 占位与插入。
enum GitHubUserAttachment {
    /// GitHub 网页附件常见上限；再大只会占 quota 并拖死评论框。
    static let maxBytes = 10 * 1_024 * 1_024

    /// `POST https://uploads.github.com/user-attachments/assets?...`
    static func makeUploadURL(
        fileName: String,
        contentType: String,
        repositoryID: Int64
    ) -> URL? {
        guard repositoryID > 0, !fileName.isEmpty, !contentType.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = AppEndpoints.GitHubUploads.baseURL.scheme
        components.host = AppEndpoints.GitHubUploads.baseURL.host
        components.path = AppEndpoints.GitHubUploads.Paths.userAttachmentAssets
        components.queryItems = [
            URLQueryItem(name: "name", value: fileName),
            URLQueryItem(name: "content_type", value: contentType),
            URLQueryItem(name: "repository_id", value: String(repositoryID)),
        ]
        return components.url
    }

    /// 成功体至少要有 `url`，且必须是 http(s)。其它字段忽略。
    static func parseAssetURL(from data: Data) throws -> URL {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw = object["url"] as? String,
            let url = URL(string: raw),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            throw GitHubUserAttachmentError.missingAssetURL
        }
        return url
    }

    static func markdownImage(alt: String, url: URL) -> String {
        let escaped = alt.replacingOccurrences(of: "]", with: "\\]")
        return "![\(escaped)](\(url.absoluteString))"
    }

    /// 上传未完成时先占位，预览最多看到 alt，不会去拉假 URL。
    static func uploadingPlaceholder(fileName: String, token: String) -> String {
        let escaped = fileName.replacingOccurrences(of: "]", with: "\\]")
        return "![Uploading \(escaped)…](starcat-upload:\(token))"
    }

    static func replacePlaceholder(_ placeholder: String, with replacement: String, in text: String) -> String {
        guard !placeholder.isEmpty, text.contains(placeholder) else { return text }
        return text.replacingOccurrences(of: placeholder, with: replacement, options: [], range: nil)
    }

    /// 按 NSTextView 的 UTF-16 选区插入块级图片，两边补空行，光标落到图后。
    static func insertBlock(
        _ snippet: String,
        into text: String,
        selectedUTF16: NSRange
    ) -> (text: String, selectedUTF16: NSRange) {
        let ns = text as NSString
        let length = ns.length
        let location = min(max(selectedUTF16.location, 0), length)
        let selectionLength = min(max(selectedUTF16.length, 0), length - location)
        let before = ns.substring(to: location)
        let after = ns.substring(from: location + selectionLength)

        let block: String
        if before.isEmpty && after.isEmpty {
            block = snippet + "\n"
        } else {
            var padded = snippet
            if !before.isEmpty && !before.hasSuffix("\n") {
                padded = "\n\n" + padded
            } else if before.hasSuffix("\n") && !before.hasSuffix("\n\n") {
                padded = "\n" + padded
            }
            if !after.isEmpty && !after.hasPrefix("\n") {
                padded += "\n\n"
            } else if after.hasPrefix("\n") && !after.hasPrefix("\n\n") {
                padded += "\n"
            }
            block = padded
        }

        let combined = before + block + after
        let cursor = (before as NSString).length + (block as NSString).length
        return (combined, NSRange(location: cursor, length: 0))
    }
}

/// 从剪贴板取出 PNG。截图常见 TIFF，统一转 PNG 再上传。
enum GitHubClipboardImage {
    struct Payload: Equatable {
        let data: Data
        let fileName: String
        let contentType: String
    }

    static func payload(from pasteboard: NSPasteboard) -> Payload? {
        if let png = pasteboard.data(forType: .png), let payload = pngPayload(png) {
            return payload
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let image = NSImage(data: tiff),
           let png = pngData(from: image),
           let payload = pngPayload(png) {
            return payload
        }
        if pasteboard.data(forType: .png) == nil,
           pasteboard.data(forType: .tiff) == nil,
           let image = NSImage(pasteboard: pasteboard),
           let png = pngData(from: image),
           let payload = pngPayload(png) {
            return payload
        }
        return nil
    }

    private static func pngPayload(_ data: Data) -> Payload? {
        guard !data.isEmpty else { return nil }
        guard data.count <= GitHubUserAttachment.maxBytes else { return nil }
        return Payload(data: data, fileName: "image.png", contentType: "image/png")
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }
}
