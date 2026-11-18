//
//  StatusBarNavigationTests.swift
//  StarcatTests
//
//  覆盖菜单树的渠道与偏好门控，以及主窗口重建期间的一次性请求。
//

import AppKit
import Testing
@testable import Starcat

@MainActor
@Suite("菜单栏导航")
struct StatusBarNavigationTests {
    @Test("Direct 将三个工作台分组，App Store 仅保留 RAG")
    func workspaceVisibilityMatchesChannel() throws {
        let direct = makeMenu(channel: .direct)
        let appStore = makeMenu(channel: .appStore)

        let directWorkspaces = try #require(direct.item(withTitle: String.l10n("menubar.group.aiWorkspaces"))?.submenu)
        #expect(directWorkspaces.items.count == 3)
        #expect(item(in: directWorkspaces, destination: .knowledgeRAGWorkspace) != nil)
        #expect(item(in: directWorkspaces, destination: .agentWorkspace) != nil)
        #expect(directWorkspaces.item(withTitle: String.l10n("skills.workspace.title")) != nil)

        #expect(item(in: direct, destination: .globalSearch) != nil)
        #expect(item(in: appStore, destination: .globalSearch) != nil)
        #expect(item(in: appStore, destination: .knowledgeRAGWorkspace) != nil)
        #expect(appStore.item(withTitle: String.l10n("menubar.group.aiWorkspaces")) == nil)
    }

    @Test("发现遵循栏目和分类显隐，收藏与账号动态需要登录")
    func discoveryAndAccountVisibilityFollowPreferences() throws {
        let weekly = MainWindowNavigationDispatcher.Destination.dailyRadar(category: "ai-weekly-events")
        let defaultDiscovery = try #require(
            makeMenu(channel: .direct).item(withTitle: String.l10n("explore.mode.discover"))?.submenu
        )
        #expect(item(in: defaultDiscovery, destination: weekly) != nil)

        let preferences = ExploreCatalogPreferences(
            hiddenModes: ["trending"],
            hiddenDailyRadarCategories: ["ai-weekly-events"]
        )
        let menu = makeMenu(channel: .direct, preferences: preferences, isAuthenticated: false)
        let discovery = try #require(menu.item(withTitle: String.l10n("explore.mode.discover"))?.submenu)
        #expect(item(in: discovery, destination: .explore(.trending)) == nil)
        #expect(item(in: discovery, destination: weekly) == nil)
        #expect(item(in: discovery, destination: .dailyRadar(category: nil)) != nil)
        #expect(item(in: discovery, destination: .explore(.recommendations))?.isEnabled == true)

        let library = try #require(menu.item(withTitle: String.l10n("menubar.group.library"))?.submenu)
        let activity = try #require(menu.item(withTitle: String.l10n("menubar.group.activity"))?.submenu)
        #expect(item(in: library, destination: .manage(.allStars))?.isEnabled == false)
        #expect(item(in: activity, destination: .githubNotifications)?.isEnabled == false)
        #expect(item(in: menu, destination: .globalSearch)?.isEnabled == true)
    }

    @Test("先登记路由再唤窗，HomeView 就绪后只消费一次")
    func navigationSurvivesWindowRecreation() {
        var activateWindow = {}
        let dispatcher = MainWindowNavigationDispatcher(activateMainWindow: { activateWindow() })
        let destinations: [MainWindowNavigationDispatcher.Destination] = [
            .globalSearch, .knowledgeRAGWorkspace, .agentWorkspace,
        ]

        for destination in destinations {
            activateWindow = {
                #expect(dispatcher.pendingRequest?.destination == destination)
            }
            dispatcher.navigate(to: destination)
            #expect(dispatcher.takePendingRequest(whenHomeIsReady: false) == nil)
            #expect(dispatcher.pendingRequest?.destination == destination)
            #expect(dispatcher.takePendingRequest(whenHomeIsReady: true)?.destination == destination)
            #expect(dispatcher.takePendingRequest(whenHomeIsReady: true) == nil)
        }
        activateWindow = {}
    }

    private func makeMenu(
        channel: DistributionChannel,
        preferences: ExploreCatalogPreferences = .init(),
        isAuthenticated: Bool = true
    ) -> NSMenu {
        StatusBarController.shared.makeMenu(
            distributionGate: DistributionGate(channel: channel),
            explorePreferences: preferences,
            isAuthenticated: isAuthenticated
        )
    }

    private func item(in menu: NSMenu, destination: MainWindowNavigationDispatcher.Destination) -> NSMenuItem? {
        menu.items.first { ($0.representedObject as? MainWindowNavigationDispatcher.Destination) == destination }
    }
}
