//
//  RepoSkillWindowController.swift
//  Starcat
//
//  Skill 安装工作区的固定 AppKit sheet 外壳。三栏尺寸由窗口持有，避免内容参与 fitting-size 协商。
//

import AppKit
import SwiftUI

/// 窗口只负责承载和关闭；来源、目录与批次由独立会话持有。
@MainActor
enum RepoSkillWindowController {

    /// 每次打开绑定当前真实仓库；同一时刻只允许一个安装 sheet。
    static func present(repo: Repo, dependencies: AppDependencies, parent: NSWindow?) {
        let session = RepoSkillSession(repo: repo, store: dependencies.repoSkillStore)
        RepoWorkspaceWindowController.present(
            identifier: "skills", title: String.l10n("repo.skills.preview.title"),
            parent: parent, dependencies: dependencies, onDismiss: { session.close() }
        ) { close in
            RepoSkillSheet(session: session, onClose: close)
        }
    }
}
