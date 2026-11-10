//
//  FollowGraphAvatarSchemeHandler.swift
//  Starcat
//
//  WebKit 图片请求到共用缓存的桥。任务停止后严禁回调 WebKit；
//  关闭画布取消本页请求，但不清除可供下次打开使用的磁盘图片。
//

import Foundation
import WebKit

/// 每个 WebView 独立持有任务表；图片缓存不依赖该 handler 的生命周期。
@MainActor
final class FollowGraphAvatarSchemeHandler: NSObject, WKURLSchemeHandler {
    private let cache: FollowGraphAvatarCache
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(cache: FollowGraphAvatarCache = .shared) { self.cache = cache }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                guard let url = urlSchemeTask.request.url else { throw URLError(.badURL) }
                let image = try await cache.image(for: url)
                guard tasks.removeValue(forKey: id) != nil, !Task.isCancelled else { return }
                urlSchemeTask.didReceive(URLResponse(
                    url: url, mimeType: image.mime, expectedContentLength: image.data.count, textEncodingName: nil
                ))
                urlSchemeTask.didReceive(image.data)
                urlSchemeTask.didFinish()
            } catch {
                guard tasks.removeValue(forKey: id) != nil, !Task.isCancelled else { return }
                urlSchemeTask.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    /// 原生拆除时立即失效，不能依赖异步 JavaScript destroy 或 WebKit 的 stop 顺序。
    func cancelAll() {
        let pending = tasks.values
        tasks.removeAll()
        for task in pending { task.cancel() }
    }
}
