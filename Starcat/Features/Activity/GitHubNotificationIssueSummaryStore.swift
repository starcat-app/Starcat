//
//  GitHubNotificationIssueSummaryStore.swift
//  Starcat
//
//  应用级 Issue 总结会话缓存。内存里只持有本次进程的任务和结果，
//  因此面板关闭 / 切帖与生成任务解耦；成功完成的总结经注入的
//  DiskIssueSummaryCache 落盘，重启后面板可回放，切换账号仍清空全部内存会话
//  （磁盘快照按公开 Issue 内容派生，跨账号共享，与 timeline 缓存同理）。
//

import Foundation

/// 字典不参与 Observation：SwiftUI body 查询已有会话不能触发整页重绘或更新循环。
@MainActor
final class GitHubNotificationIssueSummaryStore {
    private static let retainedSessionLimit = 12
    /// 成功总结的落盘出口；nil（默认，测试密闭）时退回纯内存行为。
    private let persistenceCache: DiskIssueSummaryCache?
    private var scopeRevision: UInt64?
    private var sessions: [Key: GitHubNotificationIssueSummarySession] = [:]
    private var accessOrder: [Key] = []

    init(persistenceCache: DiskIssueSummaryCache? = nil) {
        self.persistenceCache = persistenceCache
    }

    /// 同一账号、Issue 和输出语言复用同一对象；重新打开面板不会重新请求模型。
    func session(threadId: String, scopeRevision: UInt64, language: String) -> GitHubNotificationIssueSummarySession {
        if self.scopeRevision != scopeRevision { reset(scopeRevision: scopeRevision) }
        let key = Key(threadId: threadId, language: language)
        let session: GitHubNotificationIssueSummarySession
        if let existing = sessions[key] {
            session = existing
        } else {
            session = GitHubNotificationIssueSummarySession()
            if let persistenceCache {
                // 直接对属性赋值以获得完整类型上下文；经 Optional.map 推导嵌套闭包
                // 会让类型检查器超时（实测 Failed to produce diagnostic）。
                session.persistenceHook = { source, context, markdown, generatedAt in
                    persistenceCache.save(
                        title: source.title,
                        payload: source.payload,
                        timeline: source.timeline,
                        language: source.language,
                        context: context,
                        markdown: markdown,
                        generatedAt: generatedAt
                    )
                }
            }
            sessions[key] = session
        }
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
        pruneIdleSessions(keeping: key)
        return session
    }

    /// AppDependencies 在数据库账号作用域真正切换后调用；不依赖详情页是否仍在前台。
    func reset(scopeRevision: UInt64) {
        sessions.values.forEach { $0.discard() }
        sessions.removeAll()
        accessOrder.removeAll()
        self.scopeRevision = scopeRevision
    }

    /// 仅淘汰最久未查看的非运行会话；后台运行中的请求不得因浏览其它 Issue 而被停止。
    private func pruneIdleSessions(keeping current: Key) {
        while sessions.count > Self.retainedSessionLimit {
            guard let oldest = accessOrder.first(where: { key in
                key != current && sessions[key]?.isGenerating == false
            }) else { return }
            sessions.removeValue(forKey: oldest)
            accessOrder.removeAll { $0 == oldest }
        }
    }

    private struct Key: Hashable {
        let threadId: String
        let language: String
    }
}
