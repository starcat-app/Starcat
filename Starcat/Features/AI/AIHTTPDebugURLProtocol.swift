//
//  AIHTTPDebugURLProtocol.swift
//  Starcat
//
//  AI HTTP 请求 / 响应诊断拦截器。
//
//  模块职责：
//  - 拦截 MacPaw/OpenAI 发出的 `/chat/completions` 请求；
//  - 仅为非 2xx 响应保留原始 response body，让失败报告包含服务商返回结果；
//  - DEBUG 开启 AI HTTP 日志时继续输出原始 response body；
//  - 请求和响应始终原样转发给 URL Loading System，不改变 SDK 行为。
//
//  关键约束：
//  - 不拦截 embeddings，避免向量数组让日志不可读；
//  - 转发请求前设置 handled 标记，避免 URLProtocol 递归拦截自己；
//  - 成功流式响应逐块转发，不能为了抓包等待完整响应，否则聊天会失去流式效果；
//  - 失败交换仅保存在内存并在映射错误时取走，不写日志或磁盘。
//

import Foundation

/// 一次失败的 AI HTTP 交换。
///
/// MacPaw/OpenAI 对部分非标准错误体只暴露 `HTTPURLResponse`，会丢失 response body。
/// 这里保留 body，供 `OpenAIClient` 在 catch 时拼入用户主动复制的诊断报告。
struct AIHTTPFailureExchange: Sendable, Equatable {
    var url: URL?
    var statusCode: Int
    var mimeType: String?
    var requestBody: Data
    var responseBody: Data
    /// 响应体因硬上限截断时为 true，避免把失控错误页整页塞进诊断。
    var responseBodyTruncated: Bool
}

/// 线程安全的短生命周期失败交换缓存。
///
/// `URLProtocol` 回调不保证运行在调用 AI 的 actor 上，因此不能用主线程状态保存。
/// 缓存只保留最近 8 条，且 `OpenAIClient` 取到后立即删除，防止长期占用内存。
final class AIHTTPFailureExchangeStore: @unchecked Sendable {

    static let shared = AIHTTPFailureExchangeStore()

    /// 单条失败 body 上限。正常 Provider 错误 JSON 远小于此值；
    /// 用户可配任意 Base URL，必须防止恶意超大错误页撑爆进程。
    static let maxBodyBytes = 256 * 1024

    private let lock = NSLock()
    private var exchanges: [AIHTTPFailureExchange] = []

    private init() {}

    func record(_ exchange: AIHTTPFailureExchange) {
        lock.lock()
        defer { lock.unlock() }
        exchanges.append(exchange)
        if exchanges.count > 8 {
            exchanges.removeFirst(exchanges.count - 8)
        }
    }

    func take(url: URL?, statusCode: Int?) -> AIHTTPFailureExchange? {
        lock.lock()
        defer { lock.unlock() }

        // 禁止 `nil/nil` 通配：并发 chat 时会把 A 的请求/响应错绑到 B。
        guard url != nil || statusCode != nil else { return nil }

        let index = exchanges.lastIndex { exchange in
            let sameURL = url == nil || exchange.url == url
            let sameStatus = statusCode == nil || exchange.statusCode == statusCode
            return sameURL && sameStatus
        }
        guard let index else { return nil }
        return exchanges.remove(at: index)
    }
}

/// `URLProtocol` 子类，在不 fork MacPaw/OpenAI 的前提下保留失败响应体。
///
/// 实现必须使用 `URLSessionDataDelegate` 逐块转发。若改成 completion-handler 版本，
/// 成功的 SSE 流会等服务端全部结束后才交给 SDK，聊天界面将不再实时输出。
final class AIHTTPDiagnosticURLProtocol: URLProtocol, URLSessionDataDelegate, @unchecked Sendable {

    private static let handledKey = "Starcat.AIHTTPDiagnosticURLProtocol.handled"

    private var dataTask: URLSessionDataTask?
    private var forwardingSession: URLSession?
    private var receivedResponse: HTTPURLResponse?
    private var requestBody = Data()
    private var responseBody = Data()
    private var responseBodyTruncated = false

    override class func canInit(with request: URLRequest) -> Bool {
        guard URLProtocol.property(forKey: handledKey, in: request) == nil else { return false }
        guard request.url?.path.contains("/chat/completions") == true else { return false }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let mutableRequest = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest
        guard let mutableRequest else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutableRequest)
        let forwardedRequest = mutableRequest as URLRequest
        // URLSession 常把 body 内部化，protocol 侧 `httpBody` 多为空；有则截断保存，
        // 空时由 `OpenAIClient` 回退到 ChatQuery 完整编码（用户复制需要完整 prompt）。
        let rawRequestBody = forwardedRequest.httpBody ?? Data()
        if rawRequestBody.count > AIHTTPFailureExchangeStore.maxBodyBytes {
            requestBody = Data(rawRequestBody.prefix(AIHTTPFailureExchangeStore.maxBodyBytes))
        } else {
            requestBody = rawRequestBody
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = []
        forwardingSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        dataTask = forwardingSession?.dataTask(with: forwardedRequest)
        dataTask?.resume()
    }

    override func stopLoading() {
        dataTask?.cancel()
        forwardingSession?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        receivedResponse = response as? HTTPURLResponse
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let isFailure = receivedResponse.map { !(200..<300).contains($0.statusCode) } ?? false
        #if DEBUG
        if isFailure || DebugFlags.aiHTTPLogging {
            appendResponseBody(data)
        }
        #else
        if isFailure {
            appendResponseBody(data)
        }
        #endif
        client?.urlProtocol(self, didLoad: data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        defer {
            forwardingSession?.finishTasksAndInvalidate()
            forwardingSession = nil
        }

        // 非 2xx 时即便后续被 cancel / 转发出错，也尽量把已缓冲的 body 记下来。
        // MacPaw 流式路径对 4xx 可能 cancel outer task，不能只在“干净完成”时 record。
        recordFailureExchangeIfNeeded()

        if let error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        #if DEBUG
        if DebugFlags.aiHTTPLogging, let response = receivedResponse {
            AIDebugLogger.dumpRawChatHTTPResponse(
                id: UUID().uuidString,
                url: response.url,
                statusCode: response.statusCode,
                headers: response.allHeaderFields,
                body: responseBody
            )
        }
        #endif

        client?.urlProtocolDidFinishLoading(self)
    }

    private func recordFailureExchangeIfNeeded() {
        guard let response = receivedResponse,
              !(200..<300).contains(response.statusCode) else {
            return
        }
        AIHTTPFailureExchangeStore.shared.record(AIHTTPFailureExchange(
            url: response.url,
            statusCode: response.statusCode,
            mimeType: response.mimeType,
            requestBody: requestBody,
            responseBody: responseBody,
            responseBodyTruncated: responseBodyTruncated
        ))
    }

    /// 只缓冲失败诊断所需的有界 body；超限后停止追加，仍把后续 chunk 原样转给 SDK。
    private func appendResponseBody(_ data: Data) {
        guard !responseBodyTruncated else { return }
        let remaining = AIHTTPFailureExchangeStore.maxBodyBytes - responseBody.count
        if data.count <= remaining {
            responseBody.append(data)
            return
        }
        if remaining > 0 {
            responseBody.append(data.prefix(remaining))
        }
        responseBodyTruncated = true
    }
}
