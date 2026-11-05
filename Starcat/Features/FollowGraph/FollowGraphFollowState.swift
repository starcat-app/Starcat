//
//  FollowGraphFollowState.swift
//  Starcat
//
//  单个图谱账户会话的关注状态。资料卡切换不销毁写请求，避免重复关注和迟到查询回滚。
//  公开资料仍由 OwnerFollowService 缓存；这里仅保存当前账户的关系状态与操作反馈。
//

import Foundation
import Observation

/// 同一用户的写操作串行；网络确认后才更新状态，再通知图谱保存真实关系。
@MainActor @Observable
final class FollowGraphFollowState {
    /// 查询失败只能重查，不能因为保留了旧状态而把“重试”误当作关注 / 取消关注。
    enum Failure {
        case query(String)
        case write(String)

        var message: String {
            switch self {
            case .query(let message), .write(let message): return message
            }
        }
    }

    private(set) var values: [String: Bool] = [:]
    private(set) var inFlight: Set<String> = []
    private(set) var errors: [String: Failure] = [:]
    private var queries: [String: UUID] = [:]

    /// 每次选中实时查询；查询令牌防止旧读取覆盖较新的写入或另一次读取。
    func load(_ node: FollowGraphNode, service: OwnerFollowService) async {
        guard !inFlight.contains(node.id) else { return }
        let query = UUID()
        queries[node.id] = query
        errors[node.id] = nil
        do {
            let following = try await service.isFollowing(login: node.login)
            guard !Task.isCancelled, queries[node.id] == query else { return }
            values[node.id] = following
        } catch {
            guard !Task.isCancelled, queries[node.id] == query else { return }
            errors[node.id] = .query(error.localizedDescription)
        }
    }

    /// 请求成功后即使卡片已关闭也完成图谱同步；账户身份由调用方在回写前再次核对。
    func toggle(
        _ node: FollowGraphNode,
        service: OwnerFollowService,
        onSuccess: @MainActor (Bool) async -> Void
    ) async {
        guard let current = values[node.id], !inFlight.contains(node.id) else { return }
        inFlight.insert(node.id)
        queries[node.id] = nil
        errors[node.id] = nil
        defer { inFlight.remove(node.id) }
        do {
            try await service.setFollowing(!current, login: node.login)
        } catch {
            errors[node.id] = .write(error.localizedDescription)
            return
        }
        values[node.id] = !current
        await onSuccess(!current)
    }
}
