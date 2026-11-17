//
//  DiscoveryDetailPresentation.swift
//  Starcat
//
//  探索详情的展示快照与公共资料补齐状态。Hero 可见性和 README 生命周期
//  由宿主分别管理，资料请求不能成为整页展示的前置条件。
//

import Foundation
import Observation

/// 先发布列表快照，再原位补齐资料；请求身份同时区分切仓和同仓重试。
@MainActor
@Observable
final class DiscoveryDetailPresentation {
    var repo: Repo?
    private(set) var metadataFailed = false
    private(set) var metadataRequestID: UUID?

    /// 同步准备 Hero，宿主可立即启动 README，无须等待资料接口。
    func present(
        item: DiscoveryRepoDTO,
        requiresCompleteMetadata: Bool,
        registry: StarredRegistry
    ) {
        var snapshot = item.toEphemeralRepo(isStarred: false)
        if requiresCompleteMetadata {
            if let repo, repo.id == item.repoID {
                // 同仓刷新或回切打断退场时，保留已经补齐的字段，不退回不完整的列表资料。
                snapshot = repo
            } else {
                // 推荐列表没有这些计数；适配 DTO 的 0 不是接口真值。
                // nil 复用 Hero 现有占位，不能把“未知”显示成“没有关注者 / Issue”。
                snapshot.subscribersCount = nil
                snapshot.openIssuesCount = nil
            }
        }
        repo = registry.applyingDisplayState(to: snapshot)
        metadataFailed = false
        metadataRequestID = requiresCompleteMetadata ? UUID() : nil
    }

    /// 仅重试资料，不替换 Hero，也不重载 README 或重播详情切换。
    func retryMetadata() {
        guard repo != nil else { return }
        metadataFailed = false
        metadataRequestID = UUID()
    }

    /// 只允许当前请求发布结果。A → B → A 时仓库 ID 相同也不能接收第一次 A 的回包。
    ///
    /// resolve 仍复用公共资料解析器的缓存、账号检查和持久化规则；
    /// 此处只管理展示，取消不显示错误，失败不清空已有快照。
    func resolveMetadata(
        requestID: UUID,
        registry: StarredRegistry,
        resolve: () async throws -> Repo
    ) async {
        guard metadataRequestID == requestID else { return }
        do {
            let resolved = try await resolve()
            guard !Task.isCancelled, metadataRequestID == requestID else { return }
            repo = registry.applyingDisplayState(to: resolved)
            metadataFailed = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, metadataRequestID == requestID else { return }
            metadataFailed = true
        }
    }
}
