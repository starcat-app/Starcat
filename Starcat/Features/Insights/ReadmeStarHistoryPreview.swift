//
//  ReadmeStarHistoryPreview.swift
//  Starcat
//
//  README 末尾 Star History 摘要的数据编排与安全 HTML/SVG 渲染。
//
//  关键约束：
//  - README 首屏不加载历史；只有 WebView 上报接近底部后才读取缓存并刷新。
//  - 先呈现 SQLite 中可用的 GH Archive 缓存，再复用 Repository 的 ETag / 进程内
//    去重刷新；远端失败不会清空已经显示的缓存曲线。
//  - 只输出固定模板和纯文本转义后的内容，远端字段不能成为标签、属性或脚本。
//  - 全历史在 Snapshot 更新时只建模一次，最多保留 90 个绘制点；滚动期间不做 O(n) 计算。
//  - 头像先复用 Kingfisher 本地缓存，作为图片数据随卡片交给 WebView；缺图下载与历史刷新并行。
//

import Foundation

/// SwiftUI 交给 `ReadmeWebView` 的不可变 DOM 更新状态。
///
/// `revision` 是轻量身份，WebView 用它跳过重复 JavaScript；`html == nil` 表示移除摘要。
struct ReadmeStarHistoryRenderState: Equatable, Sendable {
    let revision: String
    let html: String?

    static let empty = ReadmeStarHistoryRenderState(revision: "empty", html: nil)
}

/// README 只展示公开仓库的 GH Archive 历史；零 Star 仓库可单独展示创建/当前时间线。
enum ReadmeStarHistoryVisibilityPolicy {
    static func shouldDisplay(
        repo: Repo,
        projectVisibility: ProjectVisibility?,
        snapshot: StarHistorySnapshot
    ) -> Bool {
        guard !repo.isPrivate,
              projectVisibility != .private,
              projectVisibility != .internal,
              snapshot.range == .all
        else {
            return false
        }
        // 零 Star 仓库也有 Created / Current 两个真实状态；没有历史时仅展示 Journey，不补造曲线。
        return repo.starsCount == 0 || (snapshot.points.count >= 2 && snapshot.points.contains { $0.source == .ghArchive })
    }
}

/// README Star History 的按需状态机。
///
/// SwiftUI 仍持有展示状态；Repository actor 继续作为 SQLite、ETag、请求合并和远端
/// 数据写入的唯一来源。这里不增加第二份业务缓存，只负责 cache-first 上屏与 generation 守门。
@MainActor
@Observable
final class ReadmeStarHistoryViewModel {
    typealias ProjectVisibilityProvider = @Sendable (Int64) async -> ProjectVisibility?

    private struct LoadIdentity: Hashable {
        let repo: Repo
        var repoID: Int64 { repo.id }
        let databaseScopeRevision: UInt64
        let localeIdentifier: String

        var revisionPrefix: String {
            "\(repoID)|\(databaseScopeRevision)|\(localeIdentifier)"
        }
    }

    private let repository: any RepoStarHistoryRepositoryProtocol
    private let projectVisibilityProvider: ProjectVisibilityProvider
    private var generation: UInt64 = 0
    private var activeIdentity: LoadIdentity?
    private var loadingIdentity: LoadIdentity?
    private var avatarDataURI: String?
    private var latestSnapshot: StarHistorySnapshot?

    private(set) var renderState: ReadmeStarHistoryRenderState = .empty

    init(
        repository: any RepoStarHistoryRepositoryProtocol,
        projectVisibilityProvider: @escaping ProjectVisibilityProvider
    ) {
        self.repository = repository
        self.projectVisibilityProvider = projectVisibilityProvider
    }

    /// WebView 每份文档只触发一次；这里仍按身份去重，防止 SwiftUI 更新重复提交任务。
    func loadIfNeeded(
        repo: Repo,
        databaseScopeRevision: UInt64,
        locale: Locale
    ) async {
        // 调用方会在切仓/切账号时取消 Task；先检查可挡住“已取消但尚未开始”的任务。
        guard !Task.isCancelled else { return }
        let identity = LoadIdentity(
            repo: repo,
            databaseScopeRevision: databaseScopeRevision,
            localeIdentifier: locale.identifier
        )
        if activeIdentity != identity {
            let changesRepository = activeIdentity?.repoID != identity.repoID
                || activeIdentity?.databaseScopeRevision != identity.databaseScopeRevision
            generation &+= 1
            activeIdentity = identity
            loadingIdentity = nil
            avatarDataURI = nil
            latestSnapshot = nil
            // 同仓元数据或语言更新时保留旧卡片，避免 SQLite await 期间先移除 DOM 导致滚动跳动。
            if changesRepository {
                renderState = ReadmeStarHistoryRenderState(
                    revision: "\(identity.revisionPrefix)|empty",
                    html: nil
                )
            }
        }
        guard loadingIdentity != identity else { return }

        generation &+= 1
        let requestedGeneration = generation
        loadingIdentity = identity
        defer {
            if owns(requestedGeneration, identity: identity) {
                loadingIdentity = nil
            }
        }

        // `Repo.isPrivate` 已足以拒绝公共历史，先短路可省掉一次项目表读取。
        guard owns(requestedGeneration, identity: identity), !repo.isPrivate else { return }
        let visibility = await projectVisibilityProvider(repo.id)
        guard owns(requestedGeneration, identity: identity),
              visibility != .private,
              visibility != .internal
        else { return }

        // WebKit 不读取 Kingfisher 缓存。先复用列表/详情常用尺寸，再生成带本地图片的首帧 HTML。
        if avatarDataURI == nil {
            let keys = SnapshotAvatarImage.cacheKeys(owner: repo.owner, ownerAvatar: repo.ownerAvatar, displayDiameter: 64)
            let cachedAvatar = await AvatarCacheLoader.cachedDataURI(cacheKeys: keys)
            guard owns(requestedGeneration, identity: identity) else { return }
            avatarDataURI = cachedAvatar
        }

        // 先读持久缓存。即使后续网络较慢或失败，用户到达 README 末尾时也能立即看到旧曲线。
        if let cached = try? await repository.cached(repo: repo, range: .all),
           owns(requestedGeneration, identity: identity) {
            applyIfVisible(cached, repo: repo, visibility: visibility, identity: identity, locale: locale)
        }

        // 两个结构化子任务各自发布就绪结果：曲线不等头像下载，头像也不等 History 网络刷新。
        // 它们继承调用方取消状态，并在写回前核对 generation，避免旧仓库图片覆盖新卡片。
        async let history: Void = refreshHistory(repo: repo, visibility: visibility, identity: identity,
                                                 locale: locale, requestedGeneration: requestedGeneration)
        async let avatar: Void = refreshAvatar(repo: repo, visibility: visibility, identity: identity,
                                               locale: locale, requestedGeneration: requestedGeneration)
        _ = await (history, avatar)
    }

    /// 历史刷新独立于头像请求，仍由 Repository 负责业务缓存与请求去重。
    private func refreshHistory(
        repo: Repo, visibility: ProjectVisibility?, identity: LoadIdentity,
        locale: Locale, requestedGeneration: UInt64
    ) async {
        // Repository 内部继续处理 ETag、304、同仓请求合并与本进程已加载短路。
        // README 摘要不轮询 202，避免用户只是阅读文档时产生持续后台请求。
        guard owns(requestedGeneration, identity: identity) else { return }
        guard let refreshed = try? await repository.refresh(
            repo: repo,
            range: .all,
            forceRefresh: false
        ), owns(requestedGeneration, identity: identity) else { return }

        applyIfVisible(refreshed, repo: repo, visibility: visibility, identity: identity, locale: locale)
    }

    /// 只有本地缺图才下载；加载器写回同一份 Kingfisher 缓存，后续浏览可直接复用。
    private func refreshAvatar(
        repo: Repo, visibility: ProjectVisibility?, identity: LoadIdentity,
        locale: Locale, requestedGeneration: UInt64
    ) async {
        guard avatarDataURI == nil, owns(requestedGeneration, identity: identity) else { return }
        let url = GitHubAvatarURL.imageURL(
            from: repo.ownerAvatar ?? RepoAvatarURL.from(owner: repo.owner), displayDiameter: 64
        )
        guard let dataURI = await AvatarCacheLoader.loadAsDataURI(urlString: url?.absoluteString),
              owns(requestedGeneration, identity: identity)
        else { return }
        avatarDataURI = dataURI
        // 使用当前最新快照，避免头像晚到时把已刷新的曲线回退成最初的缓存数据。
        if let snapshot = latestSnapshot {
            applyIfVisible(snapshot, repo: repo, visibility: visibility, identity: identity, locale: locale)
        }
    }

    /// 切仓、切账号或退出 README 模式时只让旧结果失去写回资格。
    ///
    /// 底层 Repository 的共享刷新可能仍会完成并落入 SQLite，供下次进入直接命中缓存。
    func cancel() {
        generation &+= 1
        activeIdentity = nil
        loadingIdentity = nil
        avatarDataURI = nil
        latestSnapshot = nil
        renderState = .empty
    }

    private func applyIfVisible(
        _ snapshot: StarHistorySnapshot,
        repo: Repo,
        visibility: ProjectVisibility?,
        identity: LoadIdentity,
        locale: Locale
    ) {
        guard ReadmeStarHistoryVisibilityPolicy.shouldDisplay(
            repo: repo,
            projectVisibility: visibility,
            snapshot: snapshot
        ) else { return }

        latestSnapshot = snapshot
        let model = StarHistoryChartRenderModel(
            points: snapshot.points,
            range: .all,
            repositoryCreatedAt: repo.createdAt.flatMap(ISO8601DateFormatter.githubDate(from:))
        )
        guard let html = ReadmeStarHistoryHTMLRenderer.render(
            snapshot: snapshot,
            model: model,
            repo: repo,
            locale: locale,
            avatarDataURI: avatarDataURI
        ) else { return }

        // 描述、Topics、覆盖水位变化也必须更新；相同 HTML 不重复触碰 DOM 和 hover 状态。
        guard renderState.html != html else { return }
        renderState = ReadmeStarHistoryRenderState(
            revision: "\(identity.revisionPrefix)|\(UUID().uuidString)",
            html: html
        )
    }

    private func owns(_ requestedGeneration: UInt64, identity: LoadIdentity) -> Bool {
        !Task.isCancelled && generation == requestedGeneration && activeIdentity == identity
    }
}
