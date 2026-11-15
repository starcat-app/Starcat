//
//  SkillRepositoryImportRequest.swift
//  Starcat
//
//  仓库详情与本机库之间只传递不可变来源证据，不传旧安装器或账号数据库会话。
//  首次导入使用预览 commit，后续检查使用来源分支，二者不相互替代。
//

import Foundation

struct SkillRepositoryImportRequest: Identifiable, Sendable {
    let repo: Repo
    let skill: RepoSkill
    var id: String { skill.id }
    var trackingRef: String { repo.defaultBranch.flatMap { $0.isEmpty ? nil : $0 } ?? "HEAD" }
}

/// 所有导入由同一个 Scene sheet 承载，避免两个窗口入口相互替换正在审核的计划。
enum SkillImportPresentation: Identifiable, Sendable {
    case manual
    case repository(SkillRepositoryImportRequest)

    var id: String {
        switch self {
        case .manual: "manual"
        case .repository(let request): request.id
        }
    }

    var repositoryRequest: SkillRepositoryImportRequest? {
        if case .repository(let request) = self { request } else { nil }
    }
}
