//
//  AwesomeSourceOpenGraph.swift
//  Starcat
//
//  来源卡片上半的 GitHub OG 图只在客户端拼 URL，不走 Discovery、不刮仓库 HTML。
//
//  为什么用 opengraph.githubassets.com：GitHub 没有稳定的 REST og:image 字段；
//  GraphQL openGraphImageUrl 在未上传 Social Preview 时经常退回 owner 头像。
//  该 CDN 接受任意缓存键，公开 HTTPS，Kingfisher 可直接拉。
//  仓库若上传了自定义 Social Preview，这条构造 URL 仍返回自动生成卡，而不是
//  repository-images 上的品牌图——本轮接受该误差，避免客户端去刮 github.com。
//
//  预拉走 Kingfisher ImagePrefetcher：已在内存/磁盘的 URL 会被 skipped，不会 forceRefresh。
//  「过期」靠 URL 里的 UTC 小时键；键变了才是新 URL，才会联网。
//

import Foundation
import Kingfisher

enum AwesomeSourceOpenGraph: Sendable {
    /// 按仓库全名拼 GitHub 自动生成的 OG 图。解析不出 `owner/repo` 时返回 nil，由卡片走 Logo 回退。
    static func imageURL(
        repoFullName: String,
        updatedAt: Date?,
        lastSyncedAt: Date?
    ) -> URL? {
        let parts = repoFullName
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }

        let cacheKey = hourKey(updatedAt ?? lastSyncedAt) ?? "1"
        let owner = encodedPathComponent(parts[0])
        let repo = encodedPathComponent(parts[1])
        return URL(string: "https://opengraph.githubassets.com/\(cacheKey)/\(owner)/\(repo)")
    }

    /// 目录里全部来源的 OG URL，非法全名跳过。同一小时键去重，避免预拉打两遍。
    static func imageURLs(for sources: [AwesomeSource]) -> [URL] {
        var seen = Set<URL>()
        var urls: [URL] = []
        urls.reserveCapacity(sources.count)
        for source in sources {
            guard let url = imageURL(
                repoFullName: source.repoFullName,
                updatedAt: source.updatedAt,
                lastSyncedAt: source.lastSyncedAt
            ) else { continue }
            if seen.insert(url).inserted {
                urls.append(url)
            }
        }
        return urls
    }

    /// 缓存优先预拉。测试 host 不打 CDN，避免单测挂网。
    /// Prefetcher 必须被 completion 抓住，否则 start() 后对象释放会把任务全部 cancel。
    static func prefetch(urls: [URL]) async {
        guard !TestEnvironment.isRunning else { return }
        let unique = imageURLsDeduped(urls)
        guard !unique.isEmpty else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let holder = PrefetcherHolder()
            holder.continuation = continuation
            let prefetcher = ImagePrefetcher(urls: unique) { _, _, _ in
                holder.finish()
            }
            holder.prefetcher = prefetcher
            prefetcher.start()
        }
    }

    /// 用 UTC 小时当缓存键：同一小时内复用 CDN / Kingfisher 缓存，跨小时才换 URL 刷新星数。
    /// GitHub 把这段标成 immutable，钉死 `1` 会让 OG 里的 Stars 长期不更新。
    private static func hourKey(_ date: Date?) -> String? {
        guard let date else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day,
              let hour = components.hour
        else { return nil }
        return String(format: "%04d%02d%02d%02d", year, month, day, hour)
    }

    private static func encodedPathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private static func imageURLsDeduped(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }
}

/// 把 ImagePrefetcher 活到 completion，避免 start 之后被释放。
private final class PrefetcherHolder: @unchecked Sendable {
    var prefetcher: ImagePrefetcher?
    var continuation: CheckedContinuation<Void, Never>?

    func finish() {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume()
        prefetcher = nil
    }
}
