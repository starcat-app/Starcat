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
//
//  2026-06-12 修订（dong4j 发现「点击分享 → 响应解析失败：未能读取数据」）：
//  - **回滚** P1-3b 加上的 `.convertToSnakeCase` / `.convertFromSnakeCase` 策略，
//    改回与 TrendingAPI / WeeklyAPI / WikiAPI 同款做法——「DTO 写显式 CodingKeys，
//    JSONEncoder/JSONDecoder 不开 strategy」。
//  - 之前注释里"strategy 不影响（CodingKeys 优先级更高）"是错的：实际行为是
//    decoder 先用 strategy 把 JSON key `schema_version` 转成 camelCase 的
//    `schemaVersion`，再去容器里按 `CodingKey.stringValue == "schema_version"`
//    查找 → **查不到** → 抛 `DecodingError.keyNotFound("schemaVersion is missing")`，
//    UI 上展示成「响应解析失败：未能读取数据，因为数据丢失。」
//  - TrendingAPI 88 行 / WeeklyAPI 95 行注释里早就警告过这个坑；ShareAPI 这次回归
//    同款规范，避免再次翻车。
//

import Foundation
import CryptoKit

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
    private let dailyRadarCacheDirectory: URL
    private var dailyRadarShares: [String: DailyRadarShareResponse] = [:]
    private var dailyRadarShareTasks: [String: Task<DailyRadarShareResponse, Error>] = [:]

    /// - Parameters:
    ///   - baseURL: 后端裸 host（**不含** `/api` 后缀，R-03.1 起与其它自建后端对齐）；
    ///     DI 装配处由 `AppDependencies` 注入，用户在设置页改地址后 `updateBaseURL(_:)` 热更新。
    ///   - apiKey: Bearer Token；DI 装配处由 `AppDependencies` 从 `StarcatAPIKeyResolver`
    ///     解析后注入；用户在设置页改 key 后 `updateAPIKey(_:)` 热更新。
    ///   - session: 注入自定义 URLSession（一般用于单测 mock）；为 nil 走默认配置。
    init(
        baseURL: URL,
        apiKey: String? = nil,
        session: URLSession? = nil,
        dailyRadarCacheDirectory: URL? = nil
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.dailyRadarCacheDirectory = dailyRadarCacheDirectory ??
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Starcat/DailyRadarShares", isDirectory: true)
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = Self.timeout
            config.timeoutIntervalForResource = Self.timeout
            self.session = URLSession(configuration: config)
        }
        // 2026-06-12：与 TrendingAPI / WeeklyAPI / WikiAPI 同款做法，**不开**
        // `.convertToSnakeCase` / `.convertFromSnakeCase` 策略——`StarcatEnvelope`
        // 顶层走显式 CodingKeys，开了 strategy 反而会与 CodingKeys 冲突，导致
        // `keyNotFound`（详见文件头 2026-06-12 修订注释 + ShareModels.swift 顶部）。
        // snake_case ↔ camelCase 的映射改由各 DTO 的显式 CodingKeys 保证。
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    /// 热更新 baseURL（用户在设置页改地址后由 `AppDependencies` 推送进来）。
    /// actor 串行化让 URL 切换无需重启 App。
    func updateBaseURL(_ url: URL) {
        self.baseURL = url
        dailyRadarShares.removeAll()
    }

    /// 热更新 API Key（用户在设置页改 key 后由 `AppDependencies` 推送进来）。
    func updateAPIKey(_ key: String?) {
        self.apiKey = key
        dailyRadarShares.removeAll()
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
        StarcatGatewayRouting.applyServiceHeader(to: &urlRequest, service: .sharing)

        do {
            urlRequest.httpBody = try encoder.encode(request)
        } catch {
            throw StarcatEnvelopeNetworkError.decoding(error)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await DiagnosticHTTP.data(for: urlRequest, using: session, service: "sharing")
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

    /// 以服务地址、完整公开快照和原图 hash 为缓存身份，避免把新 revision 或另一个服务的链接复用。
    ///
    /// actor 在 await 期间允许重入，所以运行中请求也按相同身份合并；Sheet 关闭不会取消另一位
    /// 等待者的网络请求。完成后只缓存公开响应，重新打开或重启 App 均无需再次创建。
    func shareDailyRadar(request: DailyRadarShareRequest, heroPNG: Data) async throws -> DailyRadarShareResponse {
        let canonicalEncoder = JSONEncoder()
        canonicalEncoder.outputFormatting = [.sortedKeys]
        let snapshot = try canonicalEncoder.encode(request)
        let identity = [
            baseURL.absoluteString,
            SHA256.hash(data: snapshot).map { String(format: "%02x", $0) }.joined(),
            SHA256.hash(data: heroPNG).map { String(format: "%02x", $0) }.joined()
        ].joined(separator: "|")
        let cacheKey = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        if let cached = dailyRadarShares[cacheKey] { return cached }
        let cacheFile = dailyRadarCacheDirectory.appendingPathComponent(cacheKey + ".json")
        if let bytes = try? Data(contentsOf: cacheFile),
           let cached = try? decoder.decode(DailyRadarShareResponse.self, from: bytes).validated() {
            dailyRadarShares[cacheKey] = cached
            return cached
        }
        if let pending = dailyRadarShareTasks[cacheKey] { return try await pending.value }

        let boundary = "StarcatDailyRadar-" + UUID().uuidString
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"request\"\r\nContent-Type: application/json\r\n\r\n".utf8))
        body.append(snapshot)
        body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"hero\"; filename=\"hero.png\"\r\nContent-Type: image/png\r\n\r\n".utf8))
        body.append(heroPNG)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        guard heroPNG.count <= 3_145_728, body.count <= 5_242_880 else { throw DailyRadarShareError.tooLarge }
        var upload = URLRequest(url: AppEndpoints.appendPath(AppEndpoints.Sharing.Paths.dailyRadarShares, to: baseURL))
        upload.httpMethod = "POST"
        upload.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        upload.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            upload.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        StarcatGatewayRouting.applyServiceHeader(to: &upload, service: .sharing)
        upload.httpBody = body
        let pending = Task {
            let (data, response) = try await DiagnosticHTTP.data(for: upload, using: session, service: "sharing")
            return try StarcatEnvelopeDecoder.decode(
                DailyRadarShareResponse.self, data: data, response: response, decoder: decoder
            ).validated()
        }
        dailyRadarShareTasks[cacheKey] = pending
        defer { dailyRadarShareTasks[cacheKey] = nil }
        let result = try await pending.value
        dailyRadarShares[cacheKey] = result
        // 缓存失败不影响已创建的公开链接；服务端仍提供持久幂等兜底。
        if let encoded = try? encoder.encode(result) {
            try? FileManager.default.createDirectory(at: dailyRadarCacheDirectory, withIntermediateDirectories: true)
            try? encoded.write(to: cacheFile, options: .atomic)
        }
        return result
    }
}
