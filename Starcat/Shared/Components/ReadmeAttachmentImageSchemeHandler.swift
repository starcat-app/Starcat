//
//  ReadmeAttachmentImageSchemeHandler.swift
//  Starcat
//
//  用公开 WKURLSchemeHandler 把 README 附件图片接到原始数据缓存。
//  WebKit 回调只能在任务仍有效时发送，stop 后继续 didReceive / didFinish 会触发异常。
//

import Foundation
import WebKit

/// 每个 WebView 捕获固定账户，账户变化时由视图身份重建，避免旧请求读到新账户缓存。
@MainActor
final class ReadmeAttachmentImageSchemeHandler: NSObject, WKURLSchemeHandler {
    private let accountID: Int64?
    private let cache: ReadmeAttachmentImageCache
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(accountID: Int64?, cache: ReadmeAttachmentImageCache = .shared) {
        self.accountID = accountID
        self.cache = cache
    }

    /// 等待共享图片下载，但只在 WebKit 尚未 stop 的请求上交付结果。
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                guard let url = urlSchemeTask.request.url else { throw URLError(.badURL) }
                let image = try await cache.image(for: url, accountID: accountID)
                guard tasks.removeValue(forKey: id) != nil, !Task.isCancelled else { return }
                urlSchemeTask.didReceive(URLResponse(
                    url: url, mimeType: image.mimeType, expectedContentLength: image.data.count, textEncodingName: nil
                ))
                urlSchemeTask.didReceive(image.data)
                urlSchemeTask.didFinish()
            } catch {
                guard tasks.removeValue(forKey: id) != nil, !Task.isCancelled else { return }
                urlSchemeTask.didFailWithError(error)
            }
        }
    }

    /// 单个页面退出不会取消其它页面共用的下载；清理动作由缓存 actor 统一取消。
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
}
