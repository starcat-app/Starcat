//
//  ExploreCatalogStore.swift
//  Starcat
//
//  探索页左栏元数据缓存。
//
//  设计意图：
//  - topics / platforms / languages 都是服务端可重建目录数据，不进入 SQLite；
//  - SidebarView 和 ExploreView 共用这份会话级缓存，避免 sibling 视图各自拉网络；
//  - 后端不可达时提供稳定兜底，让探索页仍能展示结构和空态。
//

import Foundation
import Observation

@MainActor
@Observable
final class ExploreCatalogStore {

    private(set) var topics: [DiscoveryTopicDTO] = []
    private(set) var platforms: [DiscoveryPlatformDTO] = []
    private(set) var languages: [DiscoveryLanguageDTO] = []
    private(set) var loadState: LoadState = .idle

    enum LoadState: Equatable {
        case idle
        case loading
        case success
        case failed(String)
    }

    private let api: DiscoveryAPI
    private var hasLoaded = false
    private var currentLoadTask: Task<Void, Never>?

    init(api: DiscoveryAPI) {
        self.api = api
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
                async let fetchedTopics = self.api.fetchTopics()
                async let fetchedPlatforms = self.api.fetchPlatforms()
                async let fetchedLanguages = self.api.fetchLanguages()

                let (topics, platforms, languages) = try await (fetchedTopics, fetchedPlatforms, fetchedLanguages)
                guard !Task.isCancelled else { return }

                if !topics.isEmpty {
                    self.topics = topics
                }
                if !platforms.isEmpty {
                    self.platforms = platforms
                }
                if !languages.isEmpty {
                    self.languages = languages
                }
                self.hasLoaded = true
                self.loadState = .success
            } catch {
                guard !Task.isCancelled else { return }
                self.loadState = .failed(error.localizedDescription)
                AppLog.network.warning("Explore catalog load failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        currentLoadTask = task
        await task.value
    }

    func invalidate() {
        hasLoaded = false
    }

    var displayTopics: [DiscoveryTopicDTO] {
        topics.isEmpty ? Self.fallbackTopics : topics
    }

    var displayPlatforms: [DiscoveryPlatformDTO] {
        platforms.isEmpty ? Self.fallbackPlatforms : platforms
    }

    var displayLanguages: [DiscoveryLanguageDTO] {
        languages.isEmpty ? Self.fallbackLanguages : languages
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
