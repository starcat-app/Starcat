//
//  AIHTTPDebugURLProtocol.swift
//  Starcat
//
//  AI HTTP 原始响应调试拦截器。
//
//  模块职责：
//  - 在 DEBUG 构建且 `DebugAIHTTPLogging` 开启时，拦截 MacPaw/OpenAI 发出的
//    `/chat/completions` 请求；
//  - 把服务商原始 HTTP response body 打印到 Xcode Console；
//  - 再把 response 原样交还给 URL Loading System，让 MacPaw/OpenAI 继续正常解码。
//
//  关键约束：
//  - 不拦截 embeddings，避免向量数组让日志不可读；
//  - 转发请求前设置 handled 标记，避免 URLProtocol 递归拦截自己；
//  - 只用于本机 Debug 诊断，Release 构建不会启用。
//

import Foundation

#if DEBUG
/// `URLProtocol` 子类，用于在不 fork MacPaw/OpenAI 的前提下观察原始 HTTP 响应。
///
/// Swift SDK 通常只暴露解码后的模型；当 LM Studio 返回格式与 OpenAI 官方格式存在细微
/// 差异时，单看 `ChatResult` 不足以判断是服务商格式问题还是 SDK 解码问题。通过给
/// `OpenAI` 注入带本 protocol 的 `URLSession`，可以在 SDK 解码前保存第一手响应。
final class AIHTTPDebugURLProtocol: URLProtocol, @unchecked Sendable {

    private static let handledKey = "Starcat.AIHTTPDebugURLProtocol.handled"

    private var dataTask: URLSessionDataTask?
    private var forwardingSession: URLSession?

    override class func canInit(with request: URLRequest) -> Bool {
        guard DebugFlags.aiHTTPLogging else { return false }
        guard URLProtocol.property(forKey: handledKey, in: request) == nil else { return false }
        guard request.url?.path.contains("/chat/completions") == true else { return false }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let id = UUID().uuidString
        let mutableRequest = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest
        guard let mutableRequest else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutableRequest)
        let forwardedRequest = mutableRequest as URLRequest

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = nil
        forwardingSession = URLSession(configuration: configuration)

        dataTask = forwardingSession?.dataTask(with: forwardedRequest) { [weak self] data, response, error in
            guard let self else { return }

            if let error {
                AppLog.ai.error("AI HTTP debug forwarding failed id=\(id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                self.client?.urlProtocol(self, didFailWithError: error)
                self.forwardingSession?.invalidateAndCancel()
                return
            }

            if let response {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }

            if let data {
                let httpResponse = response as? HTTPURLResponse
                AIDebugLogger.dumpRawChatHTTPResponse(
                    id: id,
                    url: forwardedRequest.url,
                    statusCode: httpResponse?.statusCode,
                    headers: httpResponse?.allHeaderFields ?? [:],
                    body: data
                )
                self.client?.urlProtocol(self, didLoad: data)
            }

            self.client?.urlProtocolDidFinishLoading(self)
            self.forwardingSession?.finishTasksAndInvalidate()
        }
        dataTask?.resume()
    }

    override func stopLoading() {
        dataTask?.cancel()
        forwardingSession?.invalidateAndCancel()
    }
}
#endif
