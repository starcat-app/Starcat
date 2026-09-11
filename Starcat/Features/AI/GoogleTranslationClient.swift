//
//  GoogleTranslationClient.swift
//  Starcat
//
//  README Google 翻译客户端。
//
//  关键约束：
//  - 有 API Key 时只调用 Google Cloud Translation Basic v2；
//  - 没有 API Key 时使用 Google Translate 公开网页接口，作为无配置的便利通道，
//    不把它误标成 Cloud Translation 免费额度，也不依赖其稳定 SLA；
//  - 客户端只接收纯文本，不接触 README HTML，避免翻译服务改写标签或代码结构；
//  - Cloud 路径支持一个请求携带多个 `q`，公开路径逐条请求并由上层限制并发，
//    以降低公开接口触发限流后整篇 README 失败的概率。
//

import Foundation

/// Google 翻译请求失败的稳定错误集合。
enum GoogleTranslationError: Error, LocalizedError, Equatable {
    case unauthorized
    case rateLimited
    case server(statusCode: Int)
    case invalidURL
    case invalidResponse
    case emptyResponse
    case malformedResponse
    case requestTooLarge

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return String.l10n("readme.translate.google.error.unauthorized")
        case .rateLimited:
            return String.l10n("readme.translate.google.error.rateLimited")
        case .server(let statusCode):
            return String(format: String.l10n("readme.translate.google.error.serverFormat"), statusCode)
        case .invalidURL:
            return String.l10n("readme.translate.google.error.invalidURL")
        case .invalidResponse:
            return String.l10n("readme.translate.google.error.invalidResponse")
        case .malformedResponse:
            return String.l10n("readme.translate.google.error.malformedResponse")
        case .emptyResponse:
            return String.l10n("readme.translate.google.error.emptyResponse")
        case .requestTooLarge:
            return String.l10n("readme.translate.google.error.requestTooLarge")
        }
    }
}

/// Google 两条传输路径的终点。单独抽出以便单测使用 URLProtocolStub，不访问真实网络。
struct GoogleTranslationEndpoints: Sendable {
    let cloud: URL
    let publicWeb: URL

    static let live = GoogleTranslationEndpoints(
        cloud: URL(string: "https://translation.googleapis.com/language/translate/v2")!,
        publicWeb: URL(string: "https://translate.googleapis.com/translate_a/single")!
    )
}

/// 面向 README 纯文本段落的 Google 翻译 HTTP 客户端。
final class GoogleTranslationClient: @unchecked Sendable {
    /// 加密本地凭据文件中的 service ID；Key 不进入 UserDefaults。
    static let keychainServiceID = "google-translation-api"

    enum Route: Sendable, Equatable {
        case cloud
        case publicWeb
    }

    let route: Route

    private let apiKey: String?
    private let session: URLSession
    private let endpoints: GoogleTranslationEndpoints

    init(
        apiKey: String?,
        session: URLSession = .shared,
        endpoints: GoogleTranslationEndpoints = .live
    ) {
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.apiKey = trimmedKey.isEmpty ? nil : trimmedKey
        self.route = trimmedKey.isEmpty ? .publicWeb : .cloud
        self.session = session
        self.endpoints = endpoints
    }

    /// 翻译一批纯文本。Cloud 路径一次发送整批，公开路径逐条请求。
    func translate(
        texts: [String],
        sourceLanguage: ReadmeTranslationLanguage? = nil,
        targetLanguage: ReadmeTranslationLanguage
    ) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        guard texts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw GoogleTranslationError.emptyResponse
        }

        switch route {
        case .cloud:
            return try await translateWithCloud(
                texts: texts,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
        case .publicWeb:
            return try await translateWithPublicWeb(
                texts: texts,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
        }
    }

    private func translateWithCloud(
        texts: [String],
        sourceLanguage: ReadmeTranslationLanguage?,
        targetLanguage: ReadmeTranslationLanguage
    ) async throws -> [String] {
        guard let apiKey else { throw GoogleTranslationError.unauthorized }
        guard var components = URLComponents(
            url: endpoints.cloud,
            resolvingAgainstBaseURL: false
        ) else {
            throw GoogleTranslationError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { throw GoogleTranslationError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            CloudTranslationRequest(
                queries: texts,
                target: targetLanguage.googleLanguageCode,
                source: sourceLanguage?.googleLanguageCode
            )
        )

        let data = try await load(request)
        let response = try JSONDecoder().decode(CloudTranslationResponse.self, from: data)
        let translations = response.data.translations.map(\.translatedText)
        guard translations.count == texts.count else {
            throw GoogleTranslationError.malformedResponse
        }
        return translations
    }

    private func translateWithPublicWeb(
        texts: [String],
        sourceLanguage: ReadmeTranslationLanguage?,
        targetLanguage: ReadmeTranslationLanguage
    ) async throws -> [String] {
        var translations: [String] = []
        translations.reserveCapacity(texts.count)

        for text in texts {
            try Task.checkCancellation()
            // 公开接口通过 GET 的 `q` 参数传文，过长内容容易触发 URL 限制；
            // 上层已经按 README 段落切分，这里只拦截异常大的单段，避免无意义重试。
            guard text.utf8.count <= 5_000 else {
                throw GoogleTranslationError.requestTooLarge
            }
            guard var components = URLComponents(
                url: endpoints.publicWeb,
                resolvingAgainstBaseURL: false
            ) else {
                throw GoogleTranslationError.invalidURL
            }
            components.queryItems = [
                URLQueryItem(name: "client", value: "gtx"),
                URLQueryItem(name: "sl", value: sourceLanguage?.googleLanguageCode ?? "auto"),
                URLQueryItem(name: "tl", value: targetLanguage.googleLanguageCode),
                URLQueryItem(name: "dt", value: "t"),
                URLQueryItem(name: "q", value: text)
            ]
            guard let url = components.url else { throw GoogleTranslationError.invalidURL }

            let data = try await load(URLRequest(url: url))
            translations.append(try parsePublicResponse(data))
        }
        return translations
    }

    /// 对临时限流和 5xx 做有限重试，避免一次公开接口抖动直接让整篇 README 失败。
    private func load(_ request: URLRequest) async throws -> Data {
        var retryDelay: UInt64 = 300_000_000

        for attempt in 0..<3 {
            do {
                return try await loadOnce(request)
            } catch let error as GoogleTranslationError
                where attempt < 2 && error.isTransient {
                try await Task.sleep(nanoseconds: retryDelay)
                retryDelay *= 2
            }
        }

        // `loadOnce` 在所有路径都会返回或抛出；这里仅用于满足编译器的穷尽性要求。
        throw GoogleTranslationError.invalidResponse
    }

    private func loadOnce(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleTranslationError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw GoogleTranslationError.unauthorized
        case 429:
            throw GoogleTranslationError.rateLimited
        case 400..<500:
            throw GoogleTranslationError.server(statusCode: httpResponse.statusCode)
        default:
            throw GoogleTranslationError.server(statusCode: httpResponse.statusCode)
        }
    }

    private func parsePublicResponse(_ data: Data) throws -> String {
        // `translate_a/single` 的顶层数组还包含检测到的语言等元数据，
        // 这里只消费第一个译文数组，不能把整个响应强转成 [[Any]]。
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let rows = root.first as? [[Any]]
        else {
            throw GoogleTranslationError.malformedResponse
        }

        let translated = rows.compactMap { $0.first as? String }.joined()
        guard !translated.isEmpty else { throw GoogleTranslationError.emptyResponse }
        return translated
    }
}

private extension GoogleTranslationError {
    /// 只有服务端暂时不可用或明确限流时才重试，认证/请求错误重试没有意义。
    var isTransient: Bool {
        switch self {
        case .rateLimited:
            return true
        case .server(let statusCode):
            return statusCode >= 500
        case .unauthorized, .invalidURL, .invalidResponse, .emptyResponse, .malformedResponse, .requestTooLarge:
            return false
        }
    }
}

private struct CloudTranslationRequest: Encodable {
    let queries: [String]
    let target: String
    let source: String?
    let format = "text"

    enum CodingKeys: String, CodingKey {
        case queries = "q"
        case target
        case source
        case format
    }
}

private struct CloudTranslationResponse: Decodable {
    let data: Payload

    struct Payload: Decodable {
        let translations: [Translation]
    }

    struct Translation: Decodable {
        let translatedText: String
    }
}

private extension ReadmeTranslationLanguage {
    /// Cloud Translation 使用的语言代码与 Starcat 的 BCP-47 UI 标识并不完全相同。
    var googleLanguageCode: String {
        switch resolved() {
        case .simplifiedChinese: return "zh-CN"
        case .traditionalChinese: return "zh-TW"
        case .brazilianPortuguese: return "pt"
        default: return resolved().rawValue
        }
    }
}
