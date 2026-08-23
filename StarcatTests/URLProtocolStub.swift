//
//  URLProtocolStub.swift
//  StarcatTests
//
//  Vanilla URLProtocol 子类，用于在单测里拦截 URLSession 请求并返回测试响应。
//  D-14 引入，是 `GitHubAPIClientTests` / `ReadmeAPINetworkTests` 等所有网络路径单测的基石。
//
//  设计理由：
//  - 零依赖（不引第三方 stub 库），与 Apple 推荐的 URLSession 测试做法一致
//  - 通过 `URLSessionConfiguration.protocolClasses` 注册，作用域局限在测试 session
//  - 全局 static 回调让单个测试可以快速描述"对什么请求返回什么响应"
//
//  使用模式：
//
//  ```swift
//  let session = URLProtocolStub.ephemeralSession()
//  let client = GitHubAPIClient(
//      baseURL: URL(string: "https://api.test.invalid")!,
//      session: session,
//      tokenProvider: StubTokenProvider(token: "test")
//  )
//
//  URLProtocolStub.reset()  // 强烈建议每个 @Test 开头 reset
//  URLProtocolStub.requestHandler = { request in
//      let response = HTTPURLResponse(url: request.url!, statusCode: 200, ...)!
//      return (response, jsonData)
//  }
//
//  let result = try await client.getCurrentUser()
//  ```
//
//  注意：
//  - Suite 内多个测试共享 URLProtocolStub 静态状态 → 用 `.serialized` 串行化或每个 @Test 开头 reset
//  - 不支持模拟流式响应；GitHub API 全是非流式 JSON / HTML，不影响本项目
//  - SWIFT_STRICT_CONCURRENCY = minimal（见 project.yml），故 `nonisolated(unsafe)` 静态可变即可
//

import Foundation
@testable import Starcat

final class URLProtocolStub: URLProtocol, @unchecked Sendable {

    // MARK: - Public stub API

    /// 请求处理器闭包类型：从 URLRequest 计算 (HTTPURLResponse, body)。
    /// 抛错会让 URLSession 收到 transport error（NSURLError）。
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    /// 当前活跃的请求处理器；nil 时未匹配请求会以 `URLError(.unknown)` 失败。
    /// nonisolated(unsafe)：测试用，串行化执行可接受。
    nonisolated(unsafe) static var requestHandler: Handler?

    /// 累积记录所有收到的请求；测试可断言路径 / Header / 顺序。
    nonisolated(unsafe) static var receivedRequests: [URLRequest] = []

    /// 重置全局状态。建议每个 @Test 开头调用一次，保证测试独立。
    static func reset() {
        requestHandler = nil
        receivedRequests = []
    }

    /// 便利构造：返回已注册本 stub 的 ephemeral URLSession。
    /// `ephemeral` 不写 cookie / 缓存 / 凭据，避免跨测试串扰。
    static func ephemeralSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }

    // MARK: - URLProtocol overrides

    /// 截获所有请求（要做更细的 host 匹配可在此 return false 让真实网络处理）。
    override class func canInit(with request: URLRequest) -> Bool { true }

    /// 不做 URL 规范化。
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession 可能把 URLRequest.httpBody 转成 httpBodyStream 后才交给 URLProtocol。
        // 测试需要验证 JSON 契约，因此在 stub 边界把一次性 stream 还原成 Data；这里没有
        // 下游真实网络请求，不会产生“读取两次导致空 body”的副作用。
        let capturedRequest = Self.materializedRequest(request)
        URLProtocolStub.receivedRequests.append(capturedRequest)

        guard let handler = URLProtocolStub.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(capturedRequest)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    /// no-op；本 stub 一次性返回所有数据，不存在中途取消逻辑。
    override func stopLoading() {}

    private static func materializedRequest(_ request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        var copy = request
        copy.httpBodyStream = nil
        copy.httpBody = body
        return copy
    }
}

// MARK: - 测试用 TokenProvider

/// 测试用的固定 token 提供者。
/// 业务代码 `KeychainTokenProvider` 从 Keychain 读，单测不希望真去碰 Keychain。
struct StubTokenProvider: GitHubTokenProviding {
    let token: String?
    func currentToken() async -> String? { token }
}
