//
//  SkillWorkspaceSceneRoot.swift
//  Starcat
//
//  Skill 独立窗口的原生 chrome、字号与尺寸边界。复用 Agent/RAG 的
//  Window Scene 和分栏实现，仅使用本功能自己的宽度键。
//

import AppKit
import SwiftUI

/// 中栏是目录列表，右栏是主要阅读区，因此右栏预算大于其他 AI 工作台。
enum SkillWorkspaceWindowMetrics {
    static let defaultContentSize = CGSize(width: 1440, height: 860)
    static let minimumContentSize = CGSize(width: 1040, height: 640)
    static let columnLayout = WorkspaceColumnLayout(
        left: .init(
            minimum: 180, ideal: 220, maximum: 280,
            defaultsKey: "skillWorkspace.sidebarWidth"
        ),
        right: .init(
            minimum: 480, ideal: 820, maximum: 1100,
            defaultsKey: "skillWorkspace.detailWidth"
        )
    )
}

/// 窗口级 chrome 随窗口释放，内容会话由应用级协调器保留。
struct SkillWorkspaceSceneRoot: View {
    let viewModel: SkillWorkspaceViewModel

    @State private var chromeState = WorkspaceChromeState()
    @State private var windowReference = WorkspaceSceneWindowReference()
    @State private var localeStore = LocaleStore.shared
    @Environment(\.scenePhase) private var scenePhase

    /// Scene 标题不自动跟随应用语言，沿用现有工作台的显式观察方式。
    private var windowTitle: String {
        _ = localeStore.selection
        return String.l10n("skills.workspace.title")
    }

    var body: some View {
        SkillWorkspaceView(viewModel: viewModel, chromeState: chromeState)
            .navigationTitle(windowTitle)
            .toolbar(removing: .title)
            .modifier(WorkspaceWindowSizing(
                reference: windowReference,
                minimumContentSize: SkillWorkspaceWindowMetrics.minimumContentSize
            ))
            .toolbar {
                WorkspaceToolbarContent(
                    chromeState: chromeState,
                    onPinnedChange: { isPinned in
                        windowReference.window?.level = isPinned ? .floating : .normal
                    }
                )
            }
            .starcatWindowToolbarChrome(extendsContentTintIntoToolbar: true)
            .onAppear { viewModel.startLibrary() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { viewModel.refreshLibrary() }
            }
            // macOS 可保留已关闭 Window 的 SwiftUI 树；显式窗口通知负责资源生命周期，
            // onAppear／onDisappear 仍覆盖内容树实际创建与销毁，两条路径都幂等。
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { event in
                if let window = event.object as? NSWindow, window === windowReference.window {
                    viewModel.startLibrary()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { event in
                if let window = event.object as? NSWindow, window === windowReference.window {
                    viewModel.stopLibrary()
                }
            }
            .onDisappear {
                viewModel.stopLibrary()
                windowReference.window?.level = .normal
            }
    }
}
