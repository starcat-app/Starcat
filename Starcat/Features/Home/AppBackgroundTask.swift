//
//  AppBackgroundTask.swift
//  Starcat
//
//  状态面板的只读任务行：任务身份与处理数量分离，不创建队列或保存第二份执行状态。
//

import Foundation

/// 每个执行实例只算一个任务；仓库/分片数量只在行内说明中展示。
struct AppBackgroundTask: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Sendable {
        case grouping, tags, warmup, readme, openSSF, health, indexing, repositoryIndexing
        case localModel, layaModel
        case screensaverAvatars
        case chatHistoryMigration
        case runtimeInstall

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
            case .localModel, .layaModel: "toolbar.localai.title"
            case .screensaverAvatars: "settings.general.screensaver.title"
            case .chatHistoryMigration: "settings.storage.refinement.migrating"
            case .runtimeInstall: "settings.integration.runtimeDownload.installing"
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
            case .localModel, .layaModel: .models
            case .screensaverAvatars: .general
            case .chatHistoryMigration: .storage
            case .runtimeInstall: .localTools
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
        case bytes(completed: Int64, total: Int64)
        case fraction(Double)

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
            case let .bytes(completed, total):
                guard total > 0 else { return nil }
                return "\(min(total, max(0, completed)).formatted(.byteCount(style: .file).locale(locale))) / \(total.formatted(.byteCount(style: .file).locale(locale)))"
            case .fraction(let value):
                return max(0, min(1, value)).formatted(.percent.precision(.fractionLength(0)).locale(locale))
            }
        }
    }

    /// 同类模型可以并行下载；身份使用稳定 catalog ID，不能用数组下标或显示名称。
    struct ID: Hashable, Sendable {
        let kind: Kind
        var instance: String?
    }

    let kind: Kind
    var instanceID: String?
    var id: ID { ID(kind: kind, instance: instanceID) }
    let phase: Phase
    var detail: Detail = .none
    var canCancel = false
    var opensWindow = false
    var name: String?

    var title: String { name ?? String.l10n(kind.titleKey) }
    var cancelTitleKey: String {
        kind == .localModel || kind == .layaModel ? "settings.localai.model.action.pause" : "toolbar.backgroundTasks.stop"
    }

    /// 定位复用已有设置路由；模型名与 Runtime 显示名称不参与路由解析。
    var settingsTarget: String? {
        switch kind {
        case .repositoryIndexing: "ai.index"
        case .localModel: "ai"
        case .layaModel: "labs"
        case .screensaverAvatars: "general"
        case .chatHistoryMigration: "storage"
        case .runtimeInstall: instanceID == DownloadableRuntime.codebaseMemory.rawValue
            ? "integrations.codebaseMemory" : "integrations.agentRuntime"
        default: nil
        }
    }

    init(id: Kind, phase: Phase, detail: Detail = .none, canCancel: Bool = false,
         opensWindow: Bool = false, instanceID: String? = nil, name: String? = nil) {
        self.kind = id
        self.phase = phase
        self.detail = detail
        self.canCancel = canCancel
        self.opensWindow = opensWindow
        self.instanceID = instanceID
        self.name = name
    }

    /// 安装状态由原管理器持有；暂停恢复 idle 后不伪造持久记录，加载阶段不可暂停下载。
    static func modelInstall(state: LocalAIInstallState, id: String, name: String, isLaya: Bool = false) -> Self? {
        let phase: Phase
        let detail: Detail
        let canPause: Bool
        switch state {
        case .preparing:
            phase = .preparing; detail = .none; canPause = true
        case let .downloading(_, completed, total, _):
            phase = .running; detail = .bytes(completed: completed, total: total); canPause = true
        case .loading:
            phase = .applying; detail = .none; canPause = false
        case .failed, .loadFailed:
            phase = .failed; detail = .none; canPause = false
        case .idle, .installed, .deleting, .deleteFailed:
            return nil
        }
        return Self(id: isLaya ? .layaModel : .localModel, phase: phase, detail: detail,
                    canCancel: canPause, opensWindow: true, instanceID: id, name: name)
    }

    /// 屏保只在 Direct 发布；clear() 会删除快照，不是停止本轮预取的入口。
    static func screensaverAvatars(progress: ScreensaverAvatarProgress?, channel: DistributionChannel) -> Self? {
        guard channel.isDirect, let progress else { return nil }
        return Self(id: .screensaverAvatars, phase: .running,
                    detail: .progress(processed: progress.completed, total: progress.total), opensWindow: true)
    }

    /// 存储交换只有迁移标记，没有可信数量进度或任意取消能力，面板只提供定位。
    static func chatHistoryMigration(isMigrating: Bool) -> Self? {
        isMigrating ? Self(id: .chatHistoryMigration, phase: .applying, opensWindow: true) : nil
    }

    /// 下载与配置是同一安装实例；只有下载/校验阶段可取消，等待取消不冒充已完成。
    static func runtimeInstall(_ runtime: DownloadableRuntime, state: RuntimeDownloadState) -> Self? {
        let phase: Phase
        let detail: Detail
        let canCancel: Bool
        switch state {
        case .installing(let progress):
            phase = .running; detail = progress.map(Detail.fraction) ?? .none; canCancel = true
        case .configuring:
            phase = .applying; detail = .none; canCancel = false
        case .cancelling:
            phase = .waiting; detail = .none; canCancel = false
        case .failed:
            phase = .failed; detail = .none; canCancel = false
        case .idle, .completed:
            return nil
        }
        return Self(id: .runtimeInstall, phase: phase, detail: detail, canCancel: canCancel,
                    opensWindow: true, instanceID: runtime.rawValue, name: runtime.displayName)
    }

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
