//
//  AmbientCatalogProviding.swift
//  Starcat
//
//  Ambient 卡片目录的异步边界。生产实现读取本地 Repo Repository，测试实现则可
//  注入固定结果或错误；协议保留 throws，避免把数据库故障伪装成空目录。
//

/// 为一个 Ambient 场景生成完整候选卡池。
protocol AmbientCatalogProviding: Sendable {
    func loadCards(scene: AmbientSceneKind) async throws -> [AmbientCardModel]
}

/// 轻量测试目录，也可用于 Preview / smoke 场景。
struct StaticAmbientCatalog: AmbientCatalogProviding {
    typealias Loader = @Sendable (AmbientSceneKind) async throws -> [AmbientCardModel]

    private let loader: Loader

    init(cards: [AmbientCardModel]) {
        loader = { _ in cards }
    }

    init(loader: @escaping Loader) {
        self.loader = loader
    }

    func loadCards(scene: AmbientSceneKind) async throws -> [AmbientCardModel] {
        try await loader(scene)
    }
}
