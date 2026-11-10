//
//  AppBackgroundTask.swift
//  Starcat
//
//  状态面板的只读任务行：任务身份与处理数量分离，不创建队列或保存第二份执行状态。
//

import Foundation

/// 每类服务的一轮工作只算一个任务；仓库/分片数量只在行内说明中展示。
struct AppBackgroundTask: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case grouping, tags, warmup, readme, openSSF, health, indexing, repositoryIndexing

        var titleKey: String {
            switch self {
            case .grouping: "sidebar.githubStarLists.aiGrouping.popover.title"
            case .tags: "toolbar.backgroundTasks.tags"
            case .warmup: "toolbar.backgroundTasks.warmup"
            case .readme: "toolbar.status.readmePrefetch.title"
            case .openSSF: "toolbar.backgroundTasks.openSSF"
            case .health: "toolbar.backgroundTasks.health"
            case .indexing: "toolbar.backgroundTasks.indexing"
            case .repositoryIndexing: "settings.searchIndex.repository.title"
            }
        }

        var icon: BusinessIcon.Symbol {
            switch self {
            case .grouping: .groups
            case .tags: .tags
            case .warmup: .repositories
            case .readme: .readme
            case .openSSF: .security
            case .health: .repositoryHealth
            case .indexing, .repositoryIndexing: .aiIndex
            }
        }
    }

    enum Phase: String, CaseIterable {
        case preparing, running, applying, paused, review, failed, waiting

        var titleKey: String { "toolbar.backgroundTasks.\(rawValue)" }
        var isRunning: Bool { self == .preparing || self == .running || self == .applying }
        var needsAttention: Bool { self == .review || self == .failed }
    }

    /// 待确认/失败数不是执行分母；用互斥表示防止显示成错误的 0/N。
    enum Detail: Equatable {
        case none
        case progress(processed: Int, total: Int)
        case pending(Int)
        case failed(Int)

        func text(locale: Locale) -> String? {
            switch self {
            case .none: return nil
            case let .progress(processed, total):
                guard total > 0 else { return nil }
                return "\(min(total, max(0, processed)).formatted(.number.locale(locale))) / \(total.formatted(.number.locale(locale)))"
            case .pending(let count):
                return String(format: String.l10n("aiOrganization.banner.pendingFormat"), count.formatted(.number.locale(locale)))
            case .failed(let count):
                return String(format: String.l10n("aiOrganization.banner.failedFormat"), count.formatted(.number.locale(locale)))
            }
        }
    }

    let id: Kind
    let phase: Phase
    var detail: Detail = .none
    var canCancel = false
    var opensWindow = false

    /// 仓库搜索与知识库索引独立计数；遍历结束仍有失败项时，保留入口供用户检查。
    static func repositoryIndex(
        status: SemanticIndexBuilderStatus, processed: Int, total: Int, failures: Int
    ) -> Self? {
        let phase: Phase
        let detail: Detail
        switch status {
        case .running, .paused:
            phase = status == .running ? .running : .paused
            detail = .progress(processed: processed, total: total)
        case .failed:
            phase = .failed
            detail = failures > 0 ? .failed(failures) : .none
        case .completed where failures > 0:
            phase = .failed
            detail = .failed(failures)
        case .idle, .completed, .alreadyUpToDate:
            return nil
        }
        return Self(id: .repositoryIndexing, phase: phase, detail: detail,
                    canCancel: phase == .running || phase == .paused, opensWindow: true)
    }

    /// 横幅与任务列表沿用同一套 AI 会话语义，尤其不能把分析完成误当成应用完成。
    static func organization(_ state: AIOrganizationBannerState, kind: Kind,
                             canCancel: Bool, opensWindow: Bool) -> Self? {
        let phase: Phase
        let detail: Detail
        switch state {
        case .idle: return nil
        case .preparing: phase = .preparing; detail = .none
        case let .analyzing(processed, total): phase = .running; detail = .progress(processed: processed, total: total)
        case let .applying(processed, total): phase = .applying; detail = .progress(processed: processed, total: total)
        case let .paused(processed, total): phase = .paused; detail = .progress(processed: processed, total: total)
        case .review(let count): phase = .review; detail = count > 0 ? .pending(count) : .none
        case .failed(let count): phase = .failed; detail = count > 0 ? .failed(count) : .none
        }
        return Self(id: kind, phase: phase, detail: detail,
                    canCancel: canCancel && (phase == .running || phase == .paused), opensWindow: opensWindow)
    }
}
