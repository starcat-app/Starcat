//
//  ShareAPI.swift
//  Starcat
//
//  分享 API 客户端。
//
//  R-01 v1.2 改造（2026-06-09）：
//  - endpoint `/share` → `/v1/share`（最终路径 `/api/v1/share`）
//  - 响应改 envelope 形态（`schema_version + data: ShareCreateResponse`）
//  - 强制 Bearer Auth（apiKey 字段 + Authorization 头）
//  - 错误统一走 `StarcatEnvelopeNetworkError`（不再用本地化 ShareAPIError）
//
//  R-03.1 修订（2026-06-11）：
//  - baseURL **不再**含 `/api` 后缀（之前的"特殊语义"已删），与 trending/weekly/wiki 对齐
//  - `Sharing.Paths.share = "/api/v1/share"`（绝对路径），由 `AppEndpoints.appendPath` 拼出
//  - 历史 customServiceURL 末尾 `/api` 由 `ThirdPartyService.normalizedBaseURL(_:)`
//    在保存阶段自动剥除，对本 actor 透明
//
//  R-01 P1-3b 修订（2026-06-10）：
//  - sharing-api 后端 JSON tag 全量改 snake_case，与 trending/weekly 风格一致
//  - 本 actor 的 JSONEncoder/JSONDecoder 同步设 .convertToSnakeCase /
//    .convertFromSnakeCase，Swift 端属性名仍用 camelCase（语言习惯）
//  - StarcatEnvelope / StarcatErrorEnvelope 的 schema_version 等顶层 key 走
//    explicit CodingKeys，strategy 不影响（CodingKeys 优先级更高）
//

import Foundation

/// 分享 API 客户端。
actor ShareAPI {

    private static let timeout: TimeInterval = 30

    /// 当前 baseURL；通过 `updateBaseURL(_:)` 热更新（设置页改地址后立即生效）。
    /// actor 串行化保证写入与下一次请求构造之间不会撕裂。
    private var baseURL: URL

    /// 当前 API Key（Bearer Token）；通过 `updateAPIKey(_:)` 热更新。
    /// R-01 v1.2 后端强制 Bearer Auth；nil 或空字符串 = 不带 Authorization 头（后端会 401）。
    private var apiKey: String?

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameters:
    ///   - baseURL: 后端裸 host（**不含** `/api` 后缀，R-03.1 起与其它自建后端对齐）；
    ///     DI 装配处由 `AppDependencies` 注入，用户在设置页改地址后 `updateBaseURL(_:)` 热更新。
    ///   - apiKey: Bearer Token；DI 装配处由 `AppDependencies` 从 `StarcatAPIKeyResolver`
    ///     解析后注入；用户在设置页改 key 后 `updateAPIKey(_:)` 热更新。
    ///   - session: 注入自定义 URLSession（一般用于单测 mock）；为 nil 走默认配置。
    init(
        baseURL: URL,
        apiKey: String? = nil,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = Self.timeout
            config.timeoutIntervalForResource = Self.timeout
            self.session = URLSession(configuration: config)
        }
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        // P1-3b：sharing-api 后端 JSON 字段全 snake_case；Swift 属性名仍 camelCase，
        // 靠 strategy 自动双向转换，无需在每个 DTO 写 CodingKeys。
        // StarcatEnvelope / StarcatErrorEnvelope 内部走 explicit CodingKeys，strategy 不会覆盖。
        self.encoder.keyEncodingStrategy = .convertToSnakeCase
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    /// 热更新 baseURL（用户在设置页改地址后由 `AppDependencies` 推送进来）。
    /// actor 串行化让 URL 切换无需重启 App。
    func updateBaseURL(_ url: URL) {
        AppLog.network.info("ShareAPI baseURL updated to \(url.absoluteString, privacy: .public)")
        self.baseURL = url
    }

    /// 热更新 API Key（用户在设置页改 key 后由 `AppDependencies` 推送进来）。
    /// 出于日志安全考虑不打印 key 本体，只打 prefix。
    func updateAPIKey(_ key: String?) {
        let preview = key.flatMap { $0.isEmpty ? nil : String($0.prefix(7)) } ?? "<nil>"
        AppLog.network.info("ShareAPI apiKey updated (prefix=\(preview, privacy: .public)****)")
        self.apiKey = key
    }

    /// 创建分享链接。
    ///
    /// 网络错误统一抛 `StarcatEnvelopeNetworkError`（详见 StarcatEnvelope.swift）。
    /// 401 时 `error.isUnauthorized == true`，UI 应引导用户去设置页检查 API Key。
    func shareRepo(request: ShareRepoRequest) async throws -> ShareCreateResponse {
        let url = AppEndpoints.appendPath(AppEndpoints.Sharing.Paths.share, to: baseURL)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Starcat/1.0", forHTTPHeaderField: "User-Agent")

        // R-01 v1.2：后端强制 Bearer Auth；apiKey 为 nil/空时不发头（后端会 401）。
        if let key = apiKey, !key.isEmpty {
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        do {
            urlRequest.httpBody = try encoder.encode(request)
        } catch {
            throw StarcatEnvelopeNetworkError.decoding(error)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw StarcatEnvelopeNetworkError.transport(error)
        }

        // envelope 解码 + 错误识别一气呵成（schema_version warning / 401 / 4xx / 5xx 都在内部处理）
        return try StarcatEnvelopeDecoder.decode(
            ShareCreateResponse.self,
            data: data,
            response: response,
            decoder: decoder
        )
    }
}
