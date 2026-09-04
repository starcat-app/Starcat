//
//  RepositoryLanguageDistributionViewModel.swift
//  Starcat
//
//  Manage 详情 Hero 语言分布横条的轻量状态机。
//

import Foundation
import Observation

/// 进入仓库详情后才执行 cache-first 加载，并把原始字节归一化为 Top 5 + Other 横条分段。
@MainActor
@Observable
final class RepositoryLanguageDistributionViewModel {
    /// 横条只需要语言、占比和是否可筛选；`language == nil` 表示聚合的 Other 段。
    struct Segment: Identifiable, Equatable, Sendable {
        let language: String?
        let fraction: Double

        var id: String { language ?? "__starcat_other__" }
    }

    private(set) var segments: [Segment] = []

    private let service: any RepositoryLanguageServing
    private var activeRequestID: UUID?

    init(service: any RepositoryLanguageServing) {
        self.service = service
    }

    /// 先显示本地缓存；缓存仍新鲜时不发网络，过期时保留旧值并后台刷新。
    ///
    /// `activeRequestID` 与 Task cancellation 双重守卫快速切换仓库的迟到响应，避免 A 仓库的
    /// 网络结果覆盖 B 仓库的横条。加载失败时保留 stale 缓存；cache miss 则维持中性分割线。
    func load(
        repoID: Int64,
        owner: String,
        name: String,
        now: Date = Date()
    ) async {
        guard repoID > 0 else {
            segments = []
            activeRequestID = nil
            return
        }

        let requestID = UUID()
        activeRequestID = requestID
        segments = []

        var cachedValue: RepositoryInsightsCachedValue<[String: Int]>?
        do {
            cachedValue = try await service.cachedLanguages(repoID: repoID)
        } catch {
            // 缓存异常不应阻断网络刷新；详情主内容也不能被这条装饰性分割线拖失败。
            cachedValue = nil
        }

        guard isCurrent(requestID) else { return }
        if let cachedValue {
            segments = Self.makeSegments(from: cachedValue.value)
            if !cachedValue.isStale(at: now) {
                return
            }
        }

        do {
            let refreshed = try await service.refreshLanguages(
                repoID: repoID,
                owner: owner,
                name: name
            )
            guard isCurrent(requestID) else { return }
            segments = Self.makeSegments(from: refreshed)
        } catch is CancellationError {
            return
        } catch {
            // SWR 失败时保留已上屏缓存；没有缓存时中性分割线就是稳定降级状态。
        }
    }

    /// GitHub 返回 byte count；按字节降序、语言名升序稳定排序，再把第 6 名起聚合为 Other。
    static func makeSegments(from bytesByLanguage: [String: Int]) -> [Segment] {
        let valid = bytesByLanguage
            .compactMap { language, bytes -> (language: String, bytes: Int)? in
                let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty, bytes > 0 else { return nil }
                return (normalized, bytes)
            }
            .sorted { lhs, rhs in
                lhs.bytes == rhs.bytes ? lhs.language < rhs.language : lhs.bytes > rhs.bytes
            }
        let total = valid.reduce(0) { $0 + $1.bytes }
        guard total > 0 else { return [] }

        let visible = valid.prefix(5).map { item in
            Segment(language: item.language, fraction: Double(item.bytes) / Double(total))
        }
        let otherBytes = valid.dropFirst(5).reduce(0) { $0 + $1.bytes }
        guard otherBytes > 0 else { return visible }
        return visible + [Segment(language: nil, fraction: Double(otherBytes) / Double(total))]
    }

    private func isCurrent(_ requestID: UUID) -> Bool {
        !Task.isCancelled && activeRequestID == requestID
    }
}
