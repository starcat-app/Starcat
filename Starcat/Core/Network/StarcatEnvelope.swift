//
//  StarcatEnvelope.swift
//  Starcat
//
//  Starcat 自建后端（trending / weekly / sharing / wiki）`/api/v1/*` 端点的统一响应包装。
//
//  对应文档：
//  - `docs/3-设计/详细设计/18-三场景共用架构.md` v1.2 §6.1（前端契约）
//  - `supports/docs/R-01-总体设计.md` §3.2（后端 envelope 共享代码）
//
//  ────────────────────────────────────────────────────────────────────────────
//  ⚠️ 后端 byte-level 共享代码同步约定（supports/docs/R-01-总体设计.md §4.1）
//  ────────────────────────────────────────────────────────────────────────────
//  自建后端 API 都采用同一层 envelope 语义；各服务可以自治扩展 meta，但顶层
//  `schema_version + data/meta/error` 契约必须保持兼容。
//
//  本文件是该后端 schema 在 Swift 一侧的对应物，字段一旦动也要同步：
//    - `SchemaVersion` ↔ `schemaVersion`
//    - `Data`          ↔ `data`
//    - `Meta`          ↔ `meta`
//    - `ErrorResponse` ↔ `StarcatEnvelopeError`
//  ────────────────────────────────────────────────────────────────────────────
//
//  设计意图：
//  - 让自建 API 用同一个泛型容器解码，前端零适配
//  - 顶层 `schemaVersion` + URL `/api/v1/*` 双重版本保护
//  - 错误响应自动识别（4xx / 5xx 时后端也返回 envelope 形态的 ErrorEnvelope）
//
//  Sendable：所有结构体都是值类型 + `let` 字段，T: Sendable 时自动满足。
//

import Foundation

// MARK: - 成功响应包装

/// `/api/v1/*` 200 响应的泛型顶层容器。
///
/// 字段约定（v1.2 §6.1.2 + 后端 envelope.go）：
/// ```json
/// {
///   "schema_version": 1,
///   "data": <T>,
///   "meta": { ... }   // 可选，仅分页 / 时间戳类接口才有
/// }
/// ```
///
/// 类型参数：
/// - `T = [StarcatRepoCardDTO]` —— trending / weekly 的卡片列表
/// - `T = StarcatRepoCardDTO`   —— weekly 单 repo 聚合 endpoint
/// - `T = ShareCreateResponse`  —— sharing 创建分享接口
///
/// schema 演进 SOP：
/// - **同版本内只允许加字段**（不破坏向后兼容）；老客户端忽略未知字段
/// - **改字段语义 / 删字段**（不兼容）→ 升 schemaVersion 或升 URL 版本
/// - 解码完调用 `isSupported` 判断当前客户端是否完全理解后端 schema
struct StarcatEnvelope<T: Decodable & Sendable>: Decodable, Sendable {

    /// 后端返回的 schema 版本号。必填，缺失会抛 `DecodingError.keyNotFound`。
    let schemaVersion: Int

    /// 业务数据载荷。后端始终非空（即便是空列表也会是 `[]`，不会缺字段）。
    let data: T

    /// 可选元数据（分页 / 时间戳 / 限流元信息）。仅部分 endpoint 返回。
    let meta: StarcatEnvelopeMeta?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case data
        case meta
    }

    /// 当前客户端能完全理解的最高 schema 版本。
    ///
    /// 后端升级 schema_version 时（通常加非破坏性字段），客户端版本上线前应
    /// 同步把本常量 +1。这里把它放泛型外的 enum 里是为了让所有 `StarcatEnvelope<T>`
    /// 实例化共用同一个常量（泛型类型的 static 会按 T 各自独立，不是我们要的）。
    static var supportedSchemaVersion: Int { StarcatEnvelopeSchema.supported }

    /// schema 是否在客户端能完全理解的范围内。
    ///
    /// `true`：可放心使用所有字段。
    /// `false`：客户端可能不识别新字段；上层应打 warning（`AppLog.network.warning`）
    /// 或弹「请升级 Starcat」提示，**但仍可尝试使用已解码字段**（向后兼容）。
    var isSupported: Bool { schemaVersion <= Self.supportedSchemaVersion }
}

/// 把 supportedSchemaVersion 抽出来放到非泛型 enum 里——避免 `StarcatEnvelope<T>`
/// 每实例化一个 `T` 就独立持有一份 static 常量，导致升 schema 时要在多处改。
enum StarcatEnvelopeSchema {
    /// 客户端能完全理解的最高 schema 版本。
    /// 后端升级 schema_version 时上线前同步 +1。
    static let supported: Int = 1
}

// MARK: - 元数据

/// `/api/v1/*` 响应里的可选 meta 段。
///
/// 字段集是自建 API 的并集（设计文档 §3.2）；不用的 API 自动不输出（`omitempty`），
/// 解码时一律走 `decodeIfPresent`，所有字段都可能 nil。
struct StarcatEnvelopeMeta: Decodable, Sendable, Equatable {
    /// 当前页码（1-based）。
    let page: Int?
    /// 每页大小。
    let pageSize: Int?
    /// 总数（用于推算 hasMore）。
    let total: Int?
    /// 下一页页码（后端推算好了直接给，省客户端算）。
    let nextPage: Int?
    /// trending 专用：daily / weekly / monthly。
    let since: String?
    /// trending 专用：当前请求的语言筛选。
    let language: String?
    /// 响应生成时间（RFC3339 字符串）。后端不直接给 Date 是为了跨 API 序列化语义统一。
    let generatedAt: String?
    /// 缓存状态：fresh / stale / cold。
    let cacheStatus: String?
    /// 数据爬取时间（RFC3339 字符串）。
    let fetchedAt: String?

    enum CodingKeys: String, CodingKey {
        case page
        case pageSize = "page_size"
        case total
        case nextPage = "next_page"
        case since
        case language
        case generatedAt = "generated_at"
        case cacheStatus = "cache_status"
        case fetchedAt = "fetched_at"
    }
}

// MARK: - 错误响应包装

/// `/api/v1/*` 非 2xx 响应的顶层容器。
///
/// 后端约定（auth.go writeAuthError + handler.go writeError）：
/// ```json
/// {
///   "schema_version": 1,
///   "error": {
///     "code": "UNAUTHORIZED",            // SCREAMING_SNAKE_CASE
///     "message": "missing Authorization header",
///     "details": { ... }                 // 可选结构化补充信息
///   }
/// }
/// ```
///
/// 解码失败也不致命：`StarcatEnvelopeDecoder.decode` 会先尝试拆 success，
/// 再尝试拆 error，都失败再抛 `decodingFailed`，绝不让 actor 卡住。
struct StarcatErrorEnvelope: Decodable, Sendable, Equatable {
    let schemaVersion: Int
    let error: StarcatEnvelopeError

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case error
    }
}

/// 后端 ErrorResponse 的 Swift 镜像。
///
/// `details` 字段后端是 `interface{}`，可能是 `[String: Any]` / 数组 / 字符串。
/// 这里用 `String?` 简化处理：解码时调用方一般只展示 message，details 留给调试日志。
struct StarcatEnvelopeError: Decodable, Sendable, Equatable {
    /// SCREAMING_SNAKE_CASE 错误码（如 `UNAUTHORIZED` / `BAD_REQUEST` / `NOT_FOUND` / `INTERNAL_ERROR`）。
    let code: String
    /// 用户可读错误信息。
    let message: String

    /// 已知错误码（与 R-01-总体设计 §3.5 + auth.go / handler.go 同步）。
    /// 用 String 而非 Swift enum 是因为后端可能新增错误码，前端宽松接受。
    enum KnownCode {
        static let unauthorized = "UNAUTHORIZED"
        static let badRequest = "BAD_REQUEST"
        static let notFound = "NOT_FOUND"
        static let internalError = "INTERNAL_ERROR"
    }
}

// MARK: - 解码器

/// envelope 解码统一入口。
///
/// 主要职责：
/// 1. 拿到 4xx / 5xx 响应时识别 ErrorEnvelope 形态，转 `StarcatEnvelopeNetworkError.serverError`
/// 2. 2xx 响应解 `StarcatEnvelope<T>`；schema 不兼容打 warning（不抛错）
/// 3. 解码失败统一映射到 `StarcatEnvelopeNetworkError.decoding`
///
/// 调用方约定：API actor `performRequest` 拿到 `(data, response)` 后传进来，
/// 由本 helper 决定抛错还是返回 payload。
enum StarcatEnvelopeDecoder {

    /// 给定 HTTP 响应 + 数据，解码出业务 payload；遇到任何错误都抛 `StarcatEnvelopeNetworkError`。
    ///
    /// - Parameters:
    ///   - data: HTTP body
    ///   - response: HTTP response（用 statusCode 区分 success / error）
    ///   - decoder: JSONDecoder（一般传 actor 持有的实例，已配置好策略）
    /// - Returns: T 类型的业务数据（已剥掉 envelope）
    /// - Throws: `StarcatEnvelopeNetworkError`
    static func decode<T: Decodable & Sendable>(
        _ type: T.Type,
        data: Data,
        response: URLResponse,
        decoder: JSONDecoder
    ) throws -> T {
        guard let http = response as? HTTPURLResponse else {
            throw StarcatEnvelopeNetworkError.transport(URLError(.badServerResponse))
        }

        // 4xx / 5xx：先尝试拆 ErrorEnvelope；拆不出再退化成 transport 错。
        // 后端 401 / 400 / 404 / 500 都是 ErrorEnvelope 格式，但偶发场景（fly.io 直接 502 等）
        // 可能是非 envelope 文本，所以拆失败也得给一个兜底错。
        guard (200...299).contains(http.statusCode) else {
            if let envelopeError = try? decoder.decode(StarcatErrorEnvelope.self, from: data) {
                throw StarcatEnvelopeNetworkError.serverError(
                    status: http.statusCode,
                    code: envelopeError.error.code,
                    message: envelopeError.error.message
                )
            }
            // 非 envelope 错误响应（比如 fly.io edge 直返 502 HTML）
            let raw = String(data: data, encoding: .utf8)
            throw StarcatEnvelopeNetworkError.serverError(
                status: http.statusCode,
                code: nil,
                message: raw ?? "HTTP \(http.statusCode)"
            )
        }

        // 2xx：解 success envelope。
        let envelope: StarcatEnvelope<T>
        do {
            envelope = try decoder.decode(StarcatEnvelope<T>.self, from: data)
        } catch {
            throw StarcatEnvelopeNetworkError.decoding(error)
        }

        // schema_version 不在客户端能力范围 → 打 warning，但不抛错（向前兼容）。
        // 这是 R-01 设计 §6.1.2 "客户端解码时 `schema_version > supportedSchemaVersion`
        // 应打 warning + 继续尝试解码兼容字段（不直接抛错，避免老客户端完全瘫痪）" 的实现。
        if !envelope.isSupported {
            AppLog.network.warning(
                "starcat envelope schema_version=\(envelope.schemaVersion, privacy: .public) > supported=\(StarcatEnvelopeSchema.supported, privacy: .public); 部分新字段可能未识别，建议升级 Starcat"
            )
        }

        return envelope.data
    }
}

// MARK: - 网络错误

/// 自建后端 API 的统一网络错误。
///
/// 之前每个 actor 各自有 `WeeklyAPIError` / `TrendingAPIError` / `ShareAPIError`，
/// 改造后所有走 envelope 的端点都用本枚举，case 与后端 ErrorResponse 形态对齐。
enum StarcatEnvelopeNetworkError: Error, LocalizedError, Sendable {
    /// URL 构造失败。
    case invalidURL
    /// 网络层错误（DNS / TCP / TLS / 超时 / 取消）。
    case transport(Error)
    /// 解码失败（JSON 不合法 / 字段类型不匹配 / 缺必填 key）。
    case decoding(Error)
    /// 服务端错误（带后端给的 envelope 错误码 + message；非 envelope 时 code=nil）。
    case serverError(status: Int, code: String?, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String.l10n("network.error.invalidURL")
        case .transport(let error):
            return String(format: String.l10n("network.error.transportFormat"), error.localizedDescription)
        case .decoding(let error):
            return String(format: String.l10n("network.error.decodingFormat"), error.localizedDescription)
        case .serverError(let status, let code, let message):
            // 后端 code 存在时优先展示「[CODE] message」；否则只展示 status + message。
            if let code, !code.isEmpty {
                return "[\(code)] \(message)"
            }
            return String(format: String.l10n("network.error.serverStatusFormat"), status) + ": " + message
        }
    }

    /// 是否是 401 鉴权失败（用于上层提示「请检查 API Key」）。
    var isUnauthorized: Bool {
        if case .serverError(let status, let code, _) = self {
            return status == 401 || code == StarcatEnvelopeError.KnownCode.unauthorized
        }
        return false
    }
}
