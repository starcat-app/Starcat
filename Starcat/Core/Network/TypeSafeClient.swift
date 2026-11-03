//
//  TypeSafeClient.swift
//  Starcat
//
//  TypeSafe AI(Jev)结构化决策 REST 客户端 —— 实验性功能(Labs)。
//
//  设计约束:
//  - Jev 不是 LLM:不生成文本,只对结构化 state 回答类型化问题(Noul 二元概率 /
//    Choice 多选一),本客户端只覆盖 POC 需要的 Noul 原语与通用请求骨架;
//  - 官方只有 Python / TypeScript SDK,Swift 侧按 `OpenSSFScoreAPI` 的独立公开
//    API actor 模板手写:自带 URLSession、领域错误枚举,不复用 GitHubAPIClient;
//  - 瞬时传输失败、408、429 与 5xx 的退避重试收口在本 actor 内；上层队列不再
//    对已经耗尽本层预算的 TypeSafe 错误自动重试，避免两层重试相乘;
//  - API Key 按 BYOK 逐次传入而不是构造时固化:设置页改 Key 后无需热更新装配,
//    也避免 actor 持有可变凭据状态。
//
//  已知坑(来自官方 docs.typesafe.ai/models):
//  - `jev-latest` alias 会随版本漂移,阈值调好后行为可能被 silently 改变;
//    调用方应使用固定版本 ID(如 jev-1.13.0);
//  - 限流(429)动态变化且可能不经通知调整,重试必须尊重 Retry-After。
//

import Foundation

// MARK: - 错误

/// Jev 结构化决策 API 领域错误（原生 TypeSafe 与 OpenRouter 共用）。
enum TypeSafeClientError: Error, Equatable, Sendable {
    /// 未配置 API Key(调用前应先路由回退到 LLM 路径,这里是兜底)。
    case missingAPIKey
    case unauthorized
    /// 422:请求体校验失败,body 里通常指明出错字段。
    case validation(String)
    /// 429:限流;`retryAfterSeconds` 来自 Retry-After 头(可能为 nil)。
    case rateLimited(retryAfterSeconds: Double?)
    /// 529:服务暂时过载,官方建议与 429 同样退避重试。
    case overloaded(retryAfterSeconds: Double?)
    case server(statusCode: Int)
    case transport(String)
    case decoding(String)
    /// HTTP 成功但某个必答问题缺失、类型不符或概率越界。
    case invalidAnswer(questionID: String)

    var isRetryableWithBackoff: Bool {
        switch self {
        case .rateLimited, .overloaded, .transport:
            return true
        case .server(let statusCode):
            return statusCode == 408 || (500...599).contains(statusCode)
        case .missingAPIKey, .unauthorized, .validation, .decoding, .invalidAnswer:
            return false
        }
    }

    var retryAfterSeconds: Double? {
        switch self {
        case .rateLimited(let seconds), .overloaded(let seconds):
            return seconds
        case .missingAPIKey, .unauthorized, .validation, .server, .transport, .decoding, .invalidAnswer:
            return nil
        }
    }

    var isRateLimitLike: Bool {
        switch self {
        case .rateLimited, .overloaded:
            return true
        case .missingAPIKey, .unauthorized, .validation, .server, .transport, .decoding, .invalidAnswer:
            return false
        }
    }
}

extension TypeSafeClientError: LocalizedError {
    /// 分组会话 / 批量队列的失败行直接取 `localizedDescription`;
    /// 枚举默认描述是毫无信息量的 "The operation could not be completed",
    /// 因此这里给出可读文本(技术诊断语义,与 NetworkError 的 detail 同层,不走本地化 key)。
    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Jev decision API key is not configured"
        case .unauthorized:
            return "Jev decision API rejected the key (401)"
        case let .validation(detail):
            return "Jev decision API validation error (422): \(detail)"
        case let .rateLimited(seconds):
            return "Jev decision API rate limited (429)\(seconds.map { " after \($0)s" } ?? "")"
        case let .overloaded(seconds):
            return "Jev decision API overloaded (529)\(seconds.map { " after \($0)s" } ?? "")"
        case let .server(code):
            return "Jev decision API server error (\(code))"
        case let .transport(message):
            return "Jev decision API transport error: \(message)"
        case let .decoding(message):
            return "Jev decision API response decoding failed: \(message)"
        case let .invalidAnswer(questionID):
            return "Jev decision API returned an invalid Noul answer for \(questionID)"
        }
    }
}

// MARK: - 请求 DTO

/// `POST /v1/systemone` 请求体。
/// 泛型放在类型上而不是函数内:Swift 不允许泛型函数嵌套类型。
private struct TypeSafeSystemOneRequestBody<State: Encodable>: Encodable {
    let state: State
    let model: String
    let questions: [String: TypeSafeQuestion]
}

/// Noul(true/false 语义)问题的可选判据。
///
/// criteria 不填时由模型按 instructions 自行解释;填上后概率语义被钉死,
/// 官方 cookbook(如 rerank)推荐显式给 true/false 描述以保证跨请求可比。
struct TypeSafeNoulCriteria: Encodable, Equatable {
    var `true`: String?
    var `false`: String?

    init(true: String?, false: String?) {
        self.true = `true`
        self.false = `false`
    }
}

/// TypeSafe question 的 instructions 既可以是普通文本，也可以是结构化对象。
///
/// 业务字段来自用户配置时使用 object，把固定问题与动态数据分开编码，避免引号、换行或
/// 类似指令的内容破坏问题边界。当前 Starcat 只需要字符串键值，不提前实现任意 JSON 树。
enum TypeSafeQuestionInstructions: Encodable, Equatable, ExpressibleByStringLiteral {
    case text(String)
    case object([String: String])

    init(stringLiteral value: String) {
        self = .text(value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

/// 问题原语。POC 只实现 Noul(独立二元隶属判断,天然支持「零或多个」语义);
/// Choice / Score 留待后续按需补充,不预先铺代码。
enum TypeSafeQuestion: Encodable, Equatable {
    case noul(instructions: TypeSafeQuestionInstructions, criteria: TypeSafeNoulCriteria?)

    private enum CodingKeys: String, CodingKey {
        case type
        case instructions
        case criteria
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .noul(instructions, criteria):
            try container.encode("noul", forKey: .type)
            try container.encode(instructions, forKey: .instructions)
            // criteria 整体可省;给出时 true/false 各自可省。
            if let criteria {
                try container.encode(criteria, forKey: .criteria)
            }
        }
    }
}

// MARK: - 响应 DTO

/// `POST /v1/systemone` 响应。
///
/// answers 以调用方自定义的 question id 为键;usage 只进入无业务正文的聚合诊断日志。
struct TypeSafeSystemOneResponse: Decodable, Equatable {
    let model: String?
    let answers: [String: TypeSafeAnswer]
    let usage: TypeSafeUsage?
}

/// 单个问题的答案。
///
/// Noul 答案只有概率数值;官方文档注明 confidence 仅 Choice / Score 返回,
/// 因此这里全部按可选解码,读取方各自判空。
struct TypeSafeAnswer: Decodable, Equatable {
    let type: String?
    let noul: Double?
    let choice: String?
    let probabilities: [String: Double]?
    let confidence: Double?
}

struct TypeSafeUsage: Decodable, Equatable {
    let inputTokens: Int?
    let outputTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

/// 聚合指标的固定业务分类。只允许代码内枚举值，禁止把用户输入作为日志维度。
enum TypeSafeEvaluationOperation: String, Sendable {
    case unspecified
    case githubListGrouping = "github_list_grouping"
    case tagReuse = "tag_reuse"
    case connectionTest = "connection_test"
}

/// Jev 结构化决策的承载 API。
///
/// 两条路径共享请求 / 响应协议，但 URL 与模型命名空间不同；用枚举让调用方显式选择，
/// 避免把 OpenRouter 的 Chat Completions 模型误接到 Noul 决策链路。
enum TypeSafeDecisionAPI: String, Equatable, Sendable {
    case typeSafe = "typesafe"
    case openRouter = "openrouter"
}

// MARK: - 客户端

/// TypeSafe API 独立 actor 客户端。
///
/// 并发安全:actor 隔离;无共享可变状态(URLSession / decoder 均为不可变引用),
/// 真正的并发控制由上层(分组会话的 5 Worker、批量队列)负责。
actor TypeSafeClient {
    /// 列表可能只包含别名；固定版本由设置层补齐，不把展示规则混入传输层。
    private struct ModelsResponse: Decodable {
        struct Model: Decodable {
            let name: String
        }
        let models: [Model]
    }

    private static let timeout: TimeInterval = 20
    /// 两次重试 = 最多三次传输；上层业务队列不会再对 TypeSafe 错误自动重试。
    private static let maxRetries = 2
    /// 单次调用的退避等待总预算为八秒。服务端要求更长 Retry-After 时直接把错误交给上层冷却，
    /// 不能提前重试，也不能让一个仓库长期占住五路 Worker 之一。
    private static let maxRetryDelayBudget: Double = 8
    /// 退避基数 0.5s(0.5 / 1):Jev 单次调用 70–500ms,过长退避会拖垮
    /// 分组会话的 worker 吞吐;仍优先尊重更大的 Retry-After。
    private static let backoffBaseSeconds: Double = 0.5
    private static let backoffJitterUpperBound: Double = 0.25

    private let typeSafeBaseURL: URL
    private let openRouterBaseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        baseURL: URL = AppEndpoints.TypeSafe.productionURL,
        openRouterBaseURL: URL = AppEndpoints.OpenRouterDecisions.productionURL,
        session: URLSession? = nil
    ) {
        self.typeSafeBaseURL = baseURL
        self.openRouterBaseURL = openRouterBaseURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = Self.timeout
            configuration.timeoutIntervalForResource = Self.timeout
            self.session = URLSession(configuration: configuration)
        }
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    /// 评估一次结构化决策请求。
    ///
    /// - Parameters:
    ///   - state: 任意 Encodable(对象 / 字符串 / 数组);调用方用小结构体描述
    ///     被判断对象,只带该问题需要的上下文(官方「Decompose state」原则)。
    ///   - model: 固定版本模型 ID,由 `JevDecisionEngine` 统一解析。
    ///   - questions: question id → 问题;共享同一 state,一次请求并行评估。
    ///   - apiKey: BYOK,逐次传入。
    ///   - api: 原生 TypeSafe 或 OpenRouter Decisions；默认保持原生行为。
    func evaluate<State: Encodable>(
        state: State,
        model: String,
        questions: [String: TypeSafeQuestion],
        apiKey: String,
        api: TypeSafeDecisionAPI = .typeSafe,
        operation: TypeSafeEvaluationOperation = .unspecified
    ) async throws -> TypeSafeSystemOneResponse {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw TypeSafeClientError.missingAPIKey }

        let data = try encoder.encode(
            TypeSafeSystemOneRequestBody(state: state, model: model, questions: questions)
        )

        // 两种 API 的 URL 都来自 AppEndpoints；基底可注入，测试能拦截两条路径，
        // 不需要触碰真实 TypeSafe / OpenRouter 服务。
        let target: (baseURL: URL, path: String) = switch api {
        case .typeSafe:
            (typeSafeBaseURL, AppEndpoints.TypeSafe.Paths.systemOne)
        case .openRouter:
            (openRouterBaseURL, AppEndpoints.OpenRouterDecisions.Paths.decisions)
        }
        let url = AppEndpoints.appendPath(
            target.path,
            to: target.baseURL
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Starcat/1.0", forHTTPHeaderField: "User-Agent")

        return try await sendWithRetry(
            request,
            questionCount: questions.count,
            api: api,
            operation: operation
        )
    }

    /// 获取原生模型列表，不执行推理、保存凭据或改变连接验证状态。
    func listModels(apiKey: String) async throws -> [String] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TypeSafeClientError.missingAPIKey }
        let url = AppEndpoints.appendPath(AppEndpoints.TypeSafe.Paths.models, to: typeSafeBaseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Starcat/1.0", forHTTPHeaderField: "User-Agent")
        let data = try await sendData(request)
        do {
            return try decoder.decode(ModelsResponse.self, from: data).models.map(\.name)
        } catch {
            throw TypeSafeClientError.decoding(error.localizedDescription)
        }
    }

    // MARK: - 传输与重试

    /// 一次逻辑请求只写一条聚合指标；内部退避不会制造多条成功/失败日志。
    /// 日志刻意不接收 request body、URL query 或错误详情，避免 README、规则与凭据泄露。
    private func sendWithRetry(
        _ request: URLRequest,
        questionCount: Int,
        api: TypeSafeDecisionAPI,
        operation: TypeSafeEvaluationOperation
    ) async throws -> TypeSafeSystemOneResponse {
        let startedAt = ContinuousClock.now
        var attemptCount = 0
        var failureCount = 0
        var rateLimitCount = 0
        var retryCount = 0
        var scheduledDelay: Double = 0
        let logMetrics: (String, TypeSafeUsage?, String?) -> Void = { outcome, usage, errorKind in
            Self.logRequestMetrics(
                outcome: outcome,
                api: api,
                operation: operation,
                startedAt: startedAt,
                questionCount: questionCount,
                attemptCount: attemptCount,
                failureCount: failureCount,
                rateLimitCount: rateLimitCount,
                usage: usage,
                errorKind: errorKind
            )
        }
        while true {
            do {
                attemptCount += 1
                let response = try await sendOnce(request)
                logMetrics("success", response.usage, nil)
                return response
            } catch is CancellationError {
                logMetrics("cancelled", nil, nil)
                throw CancellationError()
            } catch let error as TypeSafeClientError {
                failureCount += 1
                if error.isRateLimitLike { rateLimitCount += 1 }
                guard error.isRetryableWithBackoff,
                      retryCount < Self.maxRetries
                else {
                    logMetrics("failure", nil, Self.metricKind(for: error))
                    throw error
                }
                let delay = Self.backoffDelay(
                    after: retryCount,
                    retryHint: error.retryAfterSeconds
                )
                // 预算不足时不能无视服务端 Retry-After 提前撞回去；直接上抛后由队列级
                // 共享冷却保护其他 Worker，人工入口仍可在稍后显式重试。
                guard scheduledDelay + delay <= Self.maxRetryDelayBudget else {
                    logMetrics("failure", nil, Self.metricKind(for: error))
                    throw error
                }
                retryCount += 1
                scheduledDelay += delay
                // Task.sleep 抛 CancellationError 直接向上传播,
                // 让分组会话 / 批量队列的协作式取消立即生效。
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    logMetrics("cancelled", nil, nil)
                    throw error
                }
            }
        }
    }

    private static func logRequestMetrics(
        outcome: String,
        api: TypeSafeDecisionAPI,
        operation: TypeSafeEvaluationOperation,
        startedAt: ContinuousClock.Instant,
        questionCount: Int,
        attemptCount: Int,
        failureCount: Int,
        rateLimitCount: Int,
        usage: TypeSafeUsage?,
        errorKind: String?
    ) {
        let elapsed = startedAt.duration(to: ContinuousClock.now)
        let latencyMilliseconds = Int(elapsed.components.seconds) * 1_000
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        let inputTokens = usage?.inputTokens ?? 0
        let outputTokens = usage?.outputTokens ?? 0
        let errorKind = errorKind ?? "none"
        AppLog.ai.debug(
            "[typesafe] api=\(api.rawValue, privacy: .public) operation=\(operation.rawValue, privacy: .public) outcome=\(outcome, privacy: .public) latency_ms=\(latencyMilliseconds, privacy: .public) questions=\(questionCount, privacy: .public) attempts=\(attemptCount, privacy: .public) failures=\(failureCount, privacy: .public) rate_limits=\(rateLimitCount, privacy: .public) input_tokens=\(inputTokens, privacy: .public) output_tokens=\(outputTokens, privacy: .public) error_kind=\(errorKind, privacy: .public)"
        )
    }

    /// 指标只保留有限错误分类，不写 `localizedDescription`，避免传输层把服务端正文带入日志。
    private static func metricKind(for error: TypeSafeClientError) -> String {
        switch error {
        case .missingAPIKey:
            return "missing_api_key"
        case .unauthorized:
            return "unauthorized"
        case .validation:
            return "validation"
        case .rateLimited:
            return "rate_limited"
        case .overloaded:
            return "overloaded"
        case .server:
            return "server"
        case .transport:
            return "transport"
        case .decoding:
            return "decoding"
        case .invalidAnswer:
            return "invalid_answer"
        }
    }

    private func sendOnce(_ request: URLRequest) async throws -> TypeSafeSystemOneResponse {
        let data = try await sendData(request)
        do {
            return try decoder.decode(TypeSafeSystemOneResponse.self, from: data)
        } catch {
            throw TypeSafeClientError.decoding(error.localizedDescription)
        }
    }

    /// 两类端点共享鉴权与 HTTP 错误映射，模型列表不进入推理指标或退避队列。
    private func sendData(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TypeSafeClientError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TypeSafeClientError.transport(String.l10n("network.error.invalidResponse"))
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw TypeSafeClientError.unauthorized
        case 422:
            throw TypeSafeClientError.validation(Self.errorDetail(from: data))
        case 429:
            throw TypeSafeClientError.rateLimited(retryAfterSeconds: Self.retryAfter(from: http))
        case 529:
            throw TypeSafeClientError.overloaded(retryAfterSeconds: Self.retryAfter(from: http))
        default:
            throw TypeSafeClientError.server(statusCode: http.statusCode)
        }
    }

    private static func backoffDelay(after attempt: Int, retryHint: Double?) -> Double {
        let exponential = backoffBaseSeconds * pow(2, Double(attempt))
        let hinted = retryHint.map { min(max($0, 0), 60) } ?? 0
        // 只加正 jitter，保证不会早于 Retry-After；同时打散多个并发 Worker 的重试时刻。
        return max(exponential, hinted) + Double.random(in: 0...backoffJitterUpperBound)
    }

    /// SDK / 网关可能返回秒或毫秒版本；优先读取更精细的 retry-after-ms。
    /// 非数字（例如 HTTP-date）退回指数退避，不尝试猜测时区与服务器时钟偏差。
    private static func retryAfter(from http: HTTPURLResponse) -> Double? {
        if let rawMilliseconds = http.value(forHTTPHeaderField: "retry-after-ms"),
           let milliseconds = Double(rawMilliseconds.trimmingCharacters(in: .whitespaces)),
           milliseconds >= 0 {
            return milliseconds / 1_000
        }
        guard let raw = http.value(forHTTPHeaderField: "Retry-After") else { return nil }
        guard let seconds = Double(raw.trimmingCharacters(in: .whitespaces)), seconds >= 0 else {
            return nil
        }
        return seconds
    }

    private static func errorDetail(from data: Data) -> String {
        struct ErrorBody: Decodable {
            let detail: String?
            let message: String?
            let error: String?
        }
        guard let body = try? JSONDecoder().decode(ErrorBody.self, from: data) else {
            return String(decoding: data.prefix(240), as: UTF8.self)
        }
        return body.detail ?? body.message ?? body.error ?? String(decoding: data.prefix(240), as: UTF8.self)
    }
}
