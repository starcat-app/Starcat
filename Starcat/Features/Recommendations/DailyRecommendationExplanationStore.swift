//
//  DailyRecommendationExplanationStore.swift
//  Starcat
//
//  推荐理由是可重建的 AI 缓存，与长期推荐事实分离。仅提交当前项目及实际来源的公开资料，
//  不提交完整 Stars、负反馈或账号身份；基础来源说明始终可用，AI 失败不阻塞阅读。
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

/// 跨窗口合并同证据的生成请求；切账号立即取消并清展示，迟到结果不能回填新账号。
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

    /// 窗口关闭不丢掉已开始的付费生成；账号切换统一取消。磁盘失败保留基础依据。
    func prepare(
        item: RepoRecommendationItem, accountID: Int64, revision: UInt64, locale: String, isPro: Bool,
        generate: @escaping @MainActor (DailyRecommendationExplanationInput) async throws -> String
    ) async {
        activate(accountID: accountID, revision: revision)
        let input = DailyRecommendationExplanationInput(item)
        guard isPro, !input.sources.isEmpty, let key = try? input.cacheKey(locale: locale),
              explanations[key] == nil else { return }
        if let task = tasks[key] { _ = await task.value; return }
        let token = generation
        let disk = self.disk
        let task = Task { @MainActor () -> String? in
            do {
                if let saved = try? await disk.load(accountID: accountID, key: key) { return saved }
                try Task.checkCancellation()
                let text = try await generate(input).trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                guard !text.isEmpty else { return nil }
                // 可重建缓存写入失败不吞掉已经生成的说明；当前会话仍能复用内存结果。
                try? await disk.save(text, accountID: accountID, key: key)
                return text
            } catch { return nil }
        }
        tasks[key] = task
        let text = await task.value
        guard token == generation else { return }
        tasks[key] = nil
        if let text { explanations[key] = text }
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
        let url = file(accountID: accountID, key: key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(text).write(to: url, options: .atomic)
    }

    private func file(accountID: Int64, key: String) -> URL {
        root.appendingPathComponent(String(accountID)).appendingPathComponent(key + ".json")
    }
}
