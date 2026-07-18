//
//  ExploreCatalogStore.swift
//  Starcat
//
//  探索页左栏汇总缓存。
//
//  设计意图：
//  - topics / platforms / languages 及其 repo 数量来自 discovery summary；
//  - SidebarView 和 ExploreView 共用这份会话级缓存，避免 sibling 视图各自拉网络；
//  - 后端不可达时优先读 SQLite summary 缓存，再退回静态目录，保证探索页仍能展示结构。
//

import Foundation
import Observation

@MainActor
@Observable
final class ExploreCatalogStore {

    private(set) var summary: DiscoverySummaryDTO?
    private(set) var loadState: LoadState = .idle

    enum LoadState: Equatable {
        case idle
        case loading
        case success
        case failed(String)
    }

    private let repository: any DiscoveryRepositoryProtocol
    private var hasLoaded = false
    private var currentLoadTask: Task<Void, Never>?

    init(repository: any DiscoveryRepositoryProtocol) {
        self.repository = repository
    }

    func reload(force: Bool = false) async {
        if hasLoaded, !force {
            return
        }
        currentLoadTask?.cancel()

        let task = Task { [weak self] in
            guard let self else { return }
            self.loadState = .loading

            do {
                if let cached = await self.repository.cachedSummary() {
                    // repository 的异步实现未必会因 Task.cancel() 自动停止，回到主 actor 后必须再次校验。
                    guard !Task.isCancelled else { return }
                    self.summary = cached
                    self.hasLoaded = true
                    self.loadState = .success
                }

                let summary = try await self.repository.fetchSummary()
                guard !Task.isCancelled else { return }

                self.summary = summary
                self.hasLoaded = true
                self.loadState = .success
            } catch {
                guard !Task.isCancelled else { return }
                if let cached = await self.repository.cachedSummary() {
                    guard !Task.isCancelled else { return }
                    self.summary = cached
                    self.hasLoaded = true
                    self.loadState = .success
                } else {
                    self.loadState = .failed(error.localizedDescription)
                    AppLog.network.warning("Explore summary load failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        currentLoadTask = task
        await task.value
    }

    func invalidate() {
        hasLoaded = false
    }

    /// 接收列表 bulk 已携带的 summary，让 Sidebar 与中栏共享同一份远端快照。
    ///
    /// bulk 成功后不应再发一次 summary 请求：额外请求既浪费网络，也可能在两次请求之间
    /// 遇到后台同步，重新制造“列表与计数不一致”。取消旧任务可防止启动期较早的请求覆盖新快照。
    func apply(_ summary: DiscoverySummaryDTO) {
        currentLoadTask?.cancel()
        currentLoadTask = nil
        self.summary = summary
        hasLoaded = true
        loadState = .success
    }

    var displayTopics: [DiscoveryTopicDTO] {
        let topics = summary?
            .mode(.discover)?
            .topics?
            .map(\.asTopicDTO) ?? []
        return topics.isEmpty ? Self.fallbackTopics : topics
    }

    var displayPlatforms: [DiscoveryPlatformDTO] {
        let platforms = summary?
            .mode(.discover)?
            .platforms?
            .map(\.asPlatformDTO) ?? []
        return platforms.isEmpty ? Self.fallbackPlatforms : platforms
    }

    func displayLanguages(for mode: ExploreMode) -> [DiscoveryLanguageDTO] {
        guard let discoveryMode = mode.discoveryListMode else {
            return Self.fallbackLanguages
        }
        let languages = summary?
            .mode(discoveryMode)?
            .languages?
            .map(\.asLanguageDTO) ?? []
        return languages.isEmpty ? Self.fallbackLanguages : languages
    }

    func total(for mode: ExploreMode) -> Int? {
        guard let discoveryMode = mode.discoveryListMode else { return nil }
        return summary?.mode(discoveryMode)?.total
    }

    func topicCount(for code: String?) -> Int? {
        guard let code else {
            return total(for: .discover)
        }
        return summary?
            .mode(.discover)?
            .topics?
            .first { $0.key == code }?
            .count
    }

    func platformCount(for code: String?) -> Int? {
        guard let code else {
            return total(for: .discover)
        }
        return summary?
            .mode(.discover)?
            .platforms?
            .first { $0.key == code }?
            .count
    }

    func languageCount(for key: String?, mode: ExploreMode) -> Int? {
        guard let discoveryMode = mode.discoveryListMode else {
            return nil
        }
        guard let key else {
            return total(for: mode)
        }
        return summary?
            .mode(discoveryMode)?
            .languages?
            .first { $0.key == key }?
            .count
    }

    static let fallbackTopics: [DiscoveryTopicDTO] = [
        .init(code: "ai", label: "人工智能"),
        .init(code: "privacy", label: "隐私"),
        .init(code: "networking", label: "网络"),
        .init(code: "media", label: "媒体"),
        .init(code: "social", label: "社交"),
        .init(code: "reading", label: "阅读"),
        .init(code: "tools", label: "工具"),
    ]

    static let fallbackPlatforms: [DiscoveryPlatformDTO] = [
        .init(code: "macos", label: "macOS", systemName: "desktopcomputer"),
        .init(code: "ios", label: "iOS", systemName: "iphone"),
        .init(code: "cli", label: "CLI", systemName: "terminal"),
        .init(code: "web", label: "Web", systemName: "globe"),
        .init(code: "server", label: "Server", systemName: "server.rack"),
        .init(code: "android", label: "Android", systemName: "apps.iphone"),
        .init(code: "windows", label: "Windows", systemName: "pc"),
        .init(code: "linux", label: "Linux", systemName: "terminal"),
    ]

    static let fallbackLanguages: [DiscoveryLanguageDTO] = [
        .init(key: TrendingLanguage.uncategorizedKey, label: "Uncategorized", count: 0),
        .init(key: "JavaScript", label: "JavaScript", count: 0),
        .init(key: "TypeScript", label: "TypeScript", count: 0),
        .init(key: "Python", label: "Python", count: 0),
        .init(key: "Go", label: "Go", count: 0),
        .init(key: "Rust", label: "Rust", count: 0),
        .init(key: "Java", label: "Java", count: 0),
        .init(key: "Swift", label: "Swift", count: 0),
        .init(key: "C++", label: "C++", count: 0),
        .init(key: "Shell", label: "Shell", count: 0),
    ]
}
