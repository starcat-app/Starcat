//
//  DailyRecommendationExplanationStore.swift
//  Starcat
//
//  推荐理由在整批展示前准备并原子保存，卡片与历史详情只读相同缓存。
//  仅提交当前项目及实际来源的公开资料；基础来源说明始终可用，失败不阻塞推荐。
//

import CryptoKit
import Foundation
import Observation

/// Prompt 与缓存使用同一份证据，避免资料变化后继续复用旧理由。
struct DailyRecommendationExplanationInput: Codable, Sendable, Equatable {
    let repoID: Int64
    let fullName: String
    let description: String?
    let language: String?
    let sources: [RecommendationSeed]

    init(_ item: RepoRecommendationItem) {
        repoID = item.repoID
        fullName = item.fullName
        description = item.description
        language = item.language
        sources = item.matchedSeeds ?? []
    }

    /// 排序 JSON key 后散列；语言、提示版本与证据变化均使旧缓存失效。
    func cacheKey(locale: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(self) + Data("|v1|\(locale)".utf8)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

/// 跨窗口合并同证据的生成请求；整批有等待预算，切账号立即取消并清展示。
@MainActor
@Observable
final class DailyRecommendationExplanationStore {
    private(set) var explanations: [String: String] = [:]
    private var tasks: [String: Task<String?, Never>] = [:]
    private var accountID: Int64?
    private var revision: UInt64?
    private var generation: UInt64 = 0
    private let disk: DailyRecommendationExplanationDisk

    init(root: URL? = nil) {
        disk = DailyRecommendationExplanationDisk(root: root)
    }

    func activate(accountID: Int64?, revision: UInt64) {
        guard self.accountID != accountID || self.revision != revision else { return }
        generation &+= 1
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        explanations = [:]
        self.accountID = accountID
        self.revision = revision
    }

    /// 权益同时作用于生成和读取；曾经是 Pro 的缓存不绕过当前权益。
    func text(for item: RepoRecommendationItem, locale: String, isPro: Bool) -> String? {
        guard isPro, let key = try? DailyRecommendationExplanationInput(item).cacheKey(locale: locale) else { return nil }
        return explanations[key]
    }

    /// 历史详情只恢复已保存理由，缺缓存时展示基础依据，绝不隐式发出 LLM 请求。
    func loadSaved(
        items: [RepoRecommendationItem], accountID: Int64, revision: UInt64, locale: String, isPro: Bool
    ) async {
        guard !Task.isCancelled else { return }
        activate(accountID: accountID, revision: revision)
        guard isPro else { return }
        let token = generation
        for item in items {
            guard let key = try? DailyRecommendationExplanationInput(item).cacheKey(locale: locale),
                  explanations[key] == nil else { continue }
            let saved = try? await disk.load(accountID: accountID, key: key)
            guard token == generation, !Task.isCancelled else { return }
            if let saved, !saved.isEmpty { explanations[key] = saved }
        }
    }

    /// 只准备已过滤的实际批次，先读缓存再检查配置；非 Pro、无来源或缺配置立即兜底。
    /// 三路并发共用 30 秒截止时间，而非每个项目各等待 30 秒；失败不重试轰炸 Provider。
    func prepareBatch(
        items: [RepoRecommendationItem], accountID: Int64, revision: UInt64, locale: String, isPro: Bool,
        timeout: Duration = .seconds(30),
        checkConfiguration: @MainActor () throws -> Void = {},
        generate: @escaping @MainActor @Sendable (DailyRecommendationExplanationInput) async throws -> String
    ) async {
        guard !Task.isCancelled else { return }
        activate(accountID: accountID, revision: revision)
        let token = generation
        await loadSaved(items: items, accountID: accountID, revision: revision, locale: locale, isPro: isPro)
        guard token == generation, !Task.isCancelled, isPro else { return }
        var seen = Set<String>()
        let pending = items.filter {
            let input = DailyRecommendationExplanationInput($0)
            guard !input.sources.isEmpty, let key = try? input.cacheKey(locale: locale) else { return false }
            return explanations[key] == nil && seen.insert(key).inserted
        }
        guard !pending.isEmpty, (try? checkConfiguration()) != nil else { return }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        await withTaskGroup(of: Void.self) { group in
            var remaining = pending.makeIterator()
            for _ in 0..<min(3, pending.count) {
                if let item = remaining.next() {
                    group.addTask {
                        await self.prepare(item: item, accountID: accountID, locale: locale,
                                           deadline: deadline, token: token, generate: generate)
                    }
                }
            }
            while await group.next() != nil {
                guard !Task.isCancelled, token == generation, ContinuousClock.now < deadline else {
                    group.cancelAll()
                    return
                }
                if let item = remaining.next() {
                    group.addTask {
                        await self.prepare(item: item, accountID: accountID, locale: locale,
                                           deadline: deadline, token: token, generate: generate)
                    }
                }
            }
        }
    }

    /// 同一证据只生成一次；只把成功落盘的结果发布到内存，保存失败继续用基础依据。
    private func prepare(
        item: RepoRecommendationItem, accountID: Int64, locale: String,
        deadline: ContinuousClock.Instant, token: UInt64,
        generate: @escaping @MainActor @Sendable (DailyRecommendationExplanationInput) async throws -> String
    ) async {
        let input = DailyRecommendationExplanationInput(item)
        guard token == generation, !Task.isCancelled, ContinuousClock.now < deadline,
              let key = try? input.cacheKey(locale: locale),
              explanations[key] == nil else { return }
        if let task = tasks[key] { _ = await task.value; return }
        let disk = self.disk
        let task = Task { @MainActor () -> String? in
            await Self.generateAndSave(input: input, accountID: accountID, key: key,
                                       disk: disk, deadline: deadline, generate: generate)
        }
        tasks[key] = task
        let text = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard token == generation else { return }
        tasks[key] = nil
        if !Task.isCancelled, let text { explanations[key] = text }
    }

    /// 生成客户端可能到很晚才响应取消（尤其本地模型）。不能用等待子任务退出的超时竞赛，
    /// 否则“已超时”仍会卡住展示。Stream 截止即返回并取消工作；迟到响应在写盘前检查取消。
    private static func generateAndSave(
        input: DailyRecommendationExplanationInput, accountID: Int64, key: String,
        disk: DailyRecommendationExplanationDisk, deadline: ContinuousClock.Instant,
        generate: @escaping @MainActor @Sendable (DailyRecommendationExplanationInput) async throws -> String
    ) async -> String? {
        guard !Task.isCancelled else { return nil }
        let (stream, continuation) = AsyncStream<String>.makeStream()
        let worker = Task { @MainActor in
            defer { continuation.finish() }
            do {
                try Task.checkCancellation()
                let text = try await generate(input).trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                guard !text.isEmpty, ContinuousClock.now < deadline else { return }
                try await disk.save(text, accountID: accountID, key: key)
                try Task.checkCancellation()
                continuation.yield(text)
            } catch {
                // 请求、空结果和磁盘错误均有基础来源兜底，不变成整个推荐流程的错误。
            }
        }
        let timer = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            continuation.finish()
        }
        continuation.onTermination = { _ in
            worker.cancel()
            timer.cancel()
        }
        return await withTaskCancellationHandler {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        } onCancel: {
            continuation.finish()
        }
    }
}

/// 独立可重建缓存不依赖 repos 或推荐历史外键；文件名不含仓库名和原始 Prompt。
private actor DailyRecommendationExplanationDisk {
    private let root: URL
    init(root: URL?) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppConstants.bundleIdentifier)
            .appendingPathComponent("daily-recommendation-explanations")
    }

    func load(accountID: Int64, key: String) throws -> String? {
        let url = file(accountID: accountID, key: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(String.self, from: Data(contentsOf: url))
    }

    func save(_ text: String, accountID: Int64, key: String) throws {
        try Task.checkCancellation()
        let url = file(accountID: accountID, key: key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(text).write(to: url, options: .atomic)
    }

    private func file(accountID: Int64, key: String) -> URL {
        root.appendingPathComponent(String(accountID)).appendingPathComponent(key + ".json")
    }
}
