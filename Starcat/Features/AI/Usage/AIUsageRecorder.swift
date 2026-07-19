//
//  AIUsageRecorder.swift
//  Starcat
//
//  AI adapter 与本地 SQLite 之间的轻量写入桥梁。
//

import Foundation

protocol AIUsageRecording: Sendable {
    /// 统计写入不能改变原 AI 请求结果；实现必须吞掉持久化失败并记录诊断日志。
    func record(_ event: AIUsageEvent) async
}

/// 进程级写入桥梁。它只缓存 `DatabaseManaging` 门面，不缓存 writer，因此账号切换后
/// `record` 会自然写入新账号数据库。锁只保护一次指针读写，不包住任何数据库 await。
final class AIUsageRecorder: AIUsageRecording, @unchecked Sendable {
    static let shared = AIUsageRecorder()

    private let lock = NSLock()
    private var database: (any DatabaseManaging)?

    private init() {}

    func configure(database: any DatabaseManaging) {
        lock.withLock {
            self.database = database
        }
    }

    func record(_ event: AIUsageEvent) async {
        let database = lock.withLock { self.database }
        guard let database else { return }
        do {
            try await GRDBAIUsageRepository(database: database).insert(event)
        } catch {
            // 用量统计是旁路能力，绝不能因为磁盘满或迁移异常把用户的 AI 回答改成失败。
            AppLog.ai.error("AI usage event write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// SDK usage 到持久化事件的纯值工厂，测试可以覆盖口径而不依赖网络或 OpenAI mock。
enum AIUsageEventFactory {
    static func make(
        startedAt: Double,
        completedAt: Double = Date().timeIntervalSince1970,
        configuration: AIClientConfiguration,
        usageContext: AIUsageContext? = nil,
        model: String,
        operation: AIUsageOperation,
        inputTokens: Int?,
        outputTokens: Int?,
        totalTokens: Int?,
        cachedInputTokens: Int?,
        reasoningOutputTokens: Int?,
        itemCount: Int,
        status: AIUsageStatus,
        error: Error? = nil
    ) -> AIUsageEvent {
        let hasUsage = inputTokens != nil || outputTokens != nil || totalTokens != nil
        return AIUsageEvent(
            id: UUID().uuidString,
            startedAt: startedAt,
            completedAt: completedAt,
            durationMs: max(0, Int((completedAt - startedAt) * 1_000)),
            providerId: configuration.providerID,
            providerKind: configuration.provider.rawValue,
            model: model,
            feature: (usageContext ?? configuration.usageContext).feature.rawValue,
            phase: (usageContext ?? configuration.usageContext).phase,
            operation: operation.rawValue,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            totalTokens: totalTokens,
            cachedInputTokens: cachedInputTokens,
            reasoningOutputTokens: reasoningOutputTokens,
            itemCount: max(1, itemCount),
            usageSource: hasUsage ? AIUsageSource.provider.rawValue : AIUsageSource.unavailable.rawValue,
            status: status.rawValue,
            // 用户取消是独立终态，不属于 Provider / 网络错误；保持 NULL，避免错误分布
            // 将主动取消混入 unknown。
            errorCategory: status == .cancelled ? nil : error.map(errorCategory(for:))?.rawValue,
            correlationId: (usageContext ?? configuration.usageContext).correlationID
        )
    }

    private static func errorCategory(for error: Error) -> AIUsageErrorCategory {
        switch error {
        case AIClientError.authenticationRejected, AIEmbeddingError.authenticationRejected:
            return .authentication
        case AIClientError.rateLimited, AIEmbeddingError.rateLimited:
            return .rateLimit
        case AIClientError.paymentRequired:
            return .payment
        case AIClientError.requestRejected, AIEmbeddingError.modelRequestRejected:
            return .rejected
        case AIClientError.networkUnavailable, AIEmbeddingError.networkUnavailable:
            return .network
        case AIClientError.timedOut, AIEmbeddingError.timedOut:
            return .timeout
        case AIClientError.emptyResponse, AIClientError.responseTruncated,
             AIEmbeddingError.invalidResponse, AIEmbeddingError.emptyResponse:
            return .invalidResponse
        default:
            return .unknown
        }
    }
}
