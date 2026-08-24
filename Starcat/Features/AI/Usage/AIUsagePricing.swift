//
//  AIUsagePricing.swift
//  Starcat
//
//  基于 LiteLLM 公开模型定价目录估算 AI 请求费用，并为离线场景保留最小种子目录。
//

import Foundation

/// 一次费用估算的可持久化快照。
///
/// 历史事件保存匹配模型与目录修订号，避免定价表更新后把旧记录静默改成新价格。
struct AIUsageCostEstimate: Equatable, Sendable {
    let usd: Decimal
    let matchedModel: String
    let source: String
    let revision: String
}

/// LiteLLM 定价表中 Starcat 实际使用的字段。
///
/// 单价原始单位就是 USD/token，计算时不能再次除以一百万。LiteLLM 的其它能力字段会被
/// `JSONDecoder` 忽略，保持网络目录升级兼容。
struct LiteLLMModelPrice: Codable, Equatable, Sendable {
    let provider: String?
    let inputCostPerToken: Decimal?
    let outputCostPerToken: Decimal?
    let cacheReadInputTokenCost: Decimal?
    let cacheCreationInputTokenCost: Decimal?

    enum CodingKeys: String, CodingKey {
        case provider = "litellm_provider"
        case inputCostPerToken = "input_cost_per_token"
        case outputCostPerToken = "output_cost_per_token"
        case cacheReadInputTokenCost = "cache_read_input_token_cost"
        case cacheCreationInputTokenCost = "cache_creation_input_token_cost"
    }
}

/// 纯值费用计算器。Reasoning token 通常已经包含在 output token 中，因此不重复计费。
enum AIUsageCostCalculator {
    static func estimate(
        price: LiteLLMModelPrice,
        operation: AIUsageOperation,
        inputTokens: Int?,
        outputTokens: Int?,
        cachedInputTokens: Int?,
        cacheWriteInputTokens: Int?
    ) -> Decimal? {
        guard let inputTokens, inputTokens >= 0,
              let inputRate = price.inputCostPerToken
        else { return nil }

        let cacheRead = min(max(0, cachedInputTokens ?? 0), inputTokens)
        let remainingAfterRead = inputTokens - cacheRead
        let cacheWrite = min(max(0, cacheWriteInputTokens ?? 0), remainingAfterRead)
        let uncachedInput = max(0, inputTokens - cacheRead - cacheWrite)

        // Provider 未公布专用缓存价时按普通输入价计算，不能把这部分 token 当成免费。
        let inputCost = Decimal(uncachedInput) * inputRate
        let cacheReadCost = Decimal(cacheRead) * (price.cacheReadInputTokenCost ?? inputRate)
        let cacheWriteCost = Decimal(cacheWrite) * (price.cacheCreationInputTokenCost ?? inputRate)

        if operation == .embedding {
            return inputCost + cacheReadCost + cacheWriteCost
        }

        guard let outputTokens, outputTokens >= 0,
              let outputRate = price.outputCostPerToken
        else { return nil }
        return inputCost + cacheReadCost + cacheWriteCost + Decimal(outputTokens) * outputRate
    }
}

/// LiteLLM 定价目录。顺序是：24 小时内磁盘缓存 → 在线目录 → 过期缓存 → 内置种子。
///
/// 目录刷新是旁路能力；网络与磁盘错误只会让费用显示为不可用，绝不能影响 AI 请求本身。
actor AIModelPricingCatalog {
    static let shared = AIModelPricingCatalog()

    static let upstreamURL = URL(
        string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
    )!
    static let cacheTTL: TimeInterval = 24 * 60 * 60

    private struct CacheEnvelope: Codable, Sendable {
        let fetchedAt: Double
        let entries: [String: LiteLLMModelPrice]
    }

    private struct LoadedCatalog: Sendable {
        let entries: [String: LiteLLMModelPrice]
        let source: String
        let revision: String
    }

    private let fileManager: FileManager
    private let session: URLSession
    private let now: @Sendable () -> Date
    private let cacheURL: URL?
    private var loadedCatalog: LoadedCatalog?
    private var refreshStarted = false

    init(
        fileManager: FileManager = .default,
        session: URLSession = .shared,
        now: @escaping @Sendable () -> Date = Date.init,
        cacheURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.session = session
        self.now = now
        self.cacheURL = cacheURL ?? Self.defaultCacheURL(fileManager: fileManager)
    }

    func estimate(
        model: String,
        providerKind: String,
        operation: AIUsageOperation,
        inputTokens: Int?,
        outputTokens: Int?,
        cachedInputTokens: Int?,
        cacheWriteInputTokens: Int?
    ) async -> AIUsageCostEstimate? {
        let catalog = await catalog()
        guard let match = Self.match(model: model, providerKind: providerKind, in: catalog.entries),
              let usd = AIUsageCostCalculator.estimate(
                  price: match.price,
                  operation: operation,
                  inputTokens: inputTokens,
                  outputTokens: outputTokens,
                  cachedInputTokens: cachedInputTokens,
                  cacheWriteInputTokens: cacheWriteInputTokens
              )
        else { return nil }
        return AIUsageCostEstimate(
            usd: usd,
            matchedModel: match.key,
            source: catalog.source,
            revision: catalog.revision
        )
    }

    /// 确定性匹配优先 Provider 前缀，再匹配模型原名；不做模糊包含，避免同名模型错价。
    static func match(
        model: String,
        providerKind: String,
        in entries: [String: LiteLLMModelPrice]
    ) -> (key: String, price: LiteLLMModelPrice)? {
        let normalizedModel = normalize(model)
        guard !normalizedModel.isEmpty else { return nil }
        let provider = providerAlias(providerKind)
        var candidates: [String] = []
        if !provider.isEmpty { candidates.append("\(provider)/\(normalizedModel)") }
        candidates.append(normalizedModel)

        // UI 可能把推理强度附在模型名末尾，定价仍属于基础模型。
        let effortSuffixes = ["-xhigh", "-high", "-medium", "-low", "-minimal", "-off"]
        if let suffix = effortSuffixes.first(where: { normalizedModel.hasSuffix($0) }) {
            let base = String(normalizedModel.dropLast(suffix.count))
            if !provider.isEmpty { candidates.append("\(provider)/\(base)") }
            candidates.append(base)
        }

        var normalizedEntries: [String: (originalKey: String, price: LiteLLMModelPrice)] = [:]
        for (key, price) in entries {
            normalizedEntries[normalize(key)] = (key, price)
        }
        for candidate in candidates {
            if let entry = normalizedEntries[candidate] {
                return (entry.originalKey, entry.price)
            }
        }
        return nil
    }

    private func catalog() async -> LoadedCatalog {
        if let loadedCatalog { return loadedCatalog }

        let cached = loadCache()
        if let cached, now().timeIntervalSince1970 - cached.fetchedAt < Self.cacheTTL {
            let result = loaded(cached, source: "litellm-cache")
            loadedCatalog = result
            return result
        }

        // 费用是旁路统计，首次请求不能为了刷新公开目录额外等待最多十秒。先使用过期
        // 缓存或种子立即完成本次记录，再在 actor 外的非结构化任务中刷新下一次结果。
        let result: LoadedCatalog
        if let cached {
            result = loaded(cached, source: "litellm-stale-cache")
        } else {
            result = LoadedCatalog(
                entries: Self.seedEntries,
                source: "litellm-seed",
                revision: "seed-2026-08-24"
            )
        }
        loadedCatalog = result
        scheduleRefreshIfNeeded()
        return result
    }

    private func scheduleRefreshIfNeeded() {
        guard !refreshStarted else { return }
        refreshStarted = true
        Task { await refreshFromUpstream() }
    }

    private func refreshFromUpstream() async {
        defer { refreshStarted = false }
        do {
            var request = URLRequest(url: Self.upstreamURL)
            request.timeoutInterval = 10
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let entries = try JSONDecoder().decode([String: LiteLLMModelPrice].self, from: data)
            let envelope = CacheEnvelope(fetchedAt: now().timeIntervalSince1970, entries: entries)
            saveCache(envelope)
            loadedCatalog = loaded(envelope, source: "litellm-live")
        } catch {
            AppLog.ai.debug("LiteLLM pricing refresh skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loaded(_ envelope: CacheEnvelope, source: String) -> LoadedCatalog {
        LoadedCatalog(
            entries: envelope.entries,
            source: source,
            revision: "litellm-\(Int(envelope.fetchedAt))"
        )
    }

    private func loadCache() -> CacheEnvelope? {
        guard let cacheURL,
              let data = try? Data(contentsOf: cacheURL)
        else { return nil }
        return try? JSONDecoder().decode(CacheEnvelope.self, from: data)
    }

    private func saveCache(_ envelope: CacheEnvelope) {
        guard let cacheURL,
              let data = try? JSONEncoder().encode(envelope)
        else { return }
        do {
            try fileManager.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            AppLog.ai.warning("LiteLLM pricing cache write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func defaultCacheURL(fileManager: FileManager) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("pricing", isDirectory: true)
            .appendingPathComponent("litellm-prices.json")
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func providerAlias(_ rawValue: String) -> String {
        switch normalize(rawValue) {
        case "openaicompatible", "openai": "openai"
        case "deepseek": "deepseek"
        case "openrouter": "openrouter"
        case "azureopenai", "azure": "azure"
        case "githubmodels", "github": "github"
        case "bedrock": "bedrock"
        case "ollama": "ollama"
        case "lmstudio": "lm_studio"
        default: normalize(rawValue)
        }
    }

    /// 网络不可用时覆盖 Starcat 当前默认模型；其它模型保持“暂无定价”，不能伪装成 $0。
    private static let seedEntries: [String: LiteLLMModelPrice] = [
        "gpt-5.6": .init(provider: "openai", inputCostPerToken: 0.000004, outputCostPerToken: 0.000020, cacheReadInputTokenCost: 0.0000004, cacheCreationInputTokenCost: 0.000005),
        "gpt-5.6-sol": .init(provider: "openai", inputCostPerToken: 0.000004, outputCostPerToken: 0.000020, cacheReadInputTokenCost: 0.0000004, cacheCreationInputTokenCost: 0.000005),
        "gpt-5.6-terra": .init(provider: "openai", inputCostPerToken: 0.000002, outputCostPerToken: 0.000012, cacheReadInputTokenCost: 0.0000002, cacheCreationInputTokenCost: 0.0000025),
        "gpt-5.6-luna": .init(provider: "openai", inputCostPerToken: 0.0000002, outputCostPerToken: 0.0000012, cacheReadInputTokenCost: 0.00000002, cacheCreationInputTokenCost: 0.00000025),
        "deepseek-chat": .init(provider: "deepseek", inputCostPerToken: 0.00000028, outputCostPerToken: 0.00000042, cacheReadInputTokenCost: 0.000000028, cacheCreationInputTokenCost: nil),
        "deepseek-v4-flash": .init(provider: "deepseek", inputCostPerToken: 0.00000044, outputCostPerToken: 0.00000132, cacheReadInputTokenCost: 0.000000014, cacheCreationInputTokenCost: 0),
        "deepseek-v4-pro": .init(provider: "deepseek", inputCostPerToken: 0.00000132, outputCostPerToken: 0.00000396, cacheReadInputTokenCost: 0.000000044, cacheCreationInputTokenCost: 0),
    ]
}
