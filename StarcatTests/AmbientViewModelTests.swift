//
//  AmbientViewModelTests.swift
//  StarcatTests
//
//  覆盖加载四态、代际守门和 Reduce Motion 调度边界。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("Ambient View Model")
struct AmbientViewModelTests {
    private enum StubError: Error {
        case unavailable
    }

    @Test("成功与空目录分别进入 loaded 和 empty")
    func distinguishesLoadedAndEmpty() async throws {
        let loaded = AmbientViewModel(
            catalog: StaticAmbientCatalog(cards: [card(id: "repo:1", title: "a/one")]),
            randomSeed: { 1 }
        )
        loaded.load(scene: .repos, layout: layout, reduceMotion: true)
        try await waitUntil { loaded.state.isLoaded }

        guard case .loaded(let snapshots) = loaded.state else {
            Issue.record("Expected loaded state")
            return
        }
        #expect(snapshots.count == 4)
        #expect(!loaded.isSchedulerRunning)

        let empty = AmbientViewModel(catalog: StaticAmbientCatalog(cards: []))
        empty.load(scene: .repos, layout: layout, reduceMotion: true)
        try await waitUntil { empty.state == .empty }
    }

    @Test("Catalog 错误映射为类型化失败")
    func mapsFailureWithoutLeakingDetails() async throws {
        let catalog = StaticAmbientCatalog { _ in throw StubError.unavailable }
        let viewModel = AmbientViewModel(catalog: catalog)

        viewModel.load(scene: .repos, layout: layout, reduceMotion: true)
        try await waitUntil { viewModel.state == .failed(.repositoryUnavailable) }
    }

    @Test("旧场景迟到结果不能覆盖新场景")
    func staleGenerationCannotOverwriteNewScene() async throws {
        let gate = AmbientCardLoadGate()
        let catalog = StaticAmbientCatalog { scene in
            switch scene {
            case .repos:
                await gate.wait()
            case .owners:
                [card(id: "owner:new", title: "NewOwner")]
            }
        }
        let viewModel = AmbientViewModel(catalog: catalog, randomSeed: { 2 })

        viewModel.load(scene: .repos, layout: layout, reduceMotion: true)
        await Task.yield()
        viewModel.load(scene: .owners, layout: layout, reduceMotion: true)
        try await waitUntil {
            guard case .loaded(let snapshots) = viewModel.state else { return false }
            return snapshots.first?.card?.id == "owner:new"
        }

        await gate.resolve([card(id: "repo:old", title: "old/repo")])
        try await Task.sleep(for: .milliseconds(20))

        guard case .loaded(let snapshots) = viewModel.state else {
            Issue.record("Expected owner scene to remain loaded")
            return
        }
        #expect(viewModel.activeScene == .owners)
        #expect(snapshots.first?.card?.id == "owner:new")
    }

    @Test("Reduce Motion 加载静态网格且不创建调度 Task")
    func reduceMotionDisablesScheduler() async throws {
        let viewModel = AmbientViewModel(
            catalog: StaticAmbientCatalog(cards: [card(id: "repo:1", title: "a/one")])
        )

        viewModel.load(scene: .repos, layout: layout, reduceMotion: true)
        try await waitUntil { viewModel.state.isLoaded }

        #expect(!viewModel.isSchedulerRunning)
    }

    private var layout: AmbientGridLayout {
        AmbientGridLayout(
            config: AmbientGridConfig(rowCount: 2, columnCount: 2),
            tilePointSize: 180,
            displayScale: 2
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for Ambient state")
    }
}

private extension AmbientLoadState {
    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }
}

private actor AmbientCardLoadGate {
    private var continuation: CheckedContinuation<[AmbientCardModel], Never>?
    private var resolvedCards: [AmbientCardModel]?

    func wait() async -> [AmbientCardModel] {
        if let resolvedCards { return resolvedCards }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(_ cards: [AmbientCardModel]) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: cards)
        } else {
            resolvedCards = cards
        }
    }
}

private func card(id: String, title: String) -> AmbientCardModel {
    AmbientCardModel(
        id: id,
        visualKey: id.replacing("repo:", with: "owner:"),
        title: title,
        artworkURLString: "https://github.com/test.png",
        subtitle: nil,
        metadata: [:]
    )
}
