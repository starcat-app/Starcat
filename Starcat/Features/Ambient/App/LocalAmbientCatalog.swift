//
//  LocalAmbientCatalog.swift
//  Starcat
//
//  Ambient 的本地生产目录。它只通过注入的 RepoRepositoryProtocol 获取一次快照，
//  不直接接触 Database.shared，并把读取错误原样交给 ViewModel 映射。
//

/// 从当前用户的本地 Star 快照生成 Ambient 卡片。
struct LocalAmbientCatalog: AmbientCatalogProviding {
    typealias LoadStarred = @Sendable () async throws -> [Repo]

    private let loadStarred: LoadStarred

    init(repository: any RepoRepositoryProtocol) {
        loadStarred = {
            try await repository.fetchAllStarred()
        }
    }

    /// 测试边界：只替换 repository 的单个读取动作，避免为一个查询伪造整套大协议。
    init(loadStarred: @escaping LoadStarred) {
        self.loadStarred = loadStarred
    }

    func loadCards(scene: AmbientSceneKind) async throws -> [AmbientCardModel] {
        let repos = try await loadStarred()
        return AmbientCardFactory.cards(from: repos, scene: scene)
    }
}
