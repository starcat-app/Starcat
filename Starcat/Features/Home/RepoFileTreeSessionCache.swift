//
//  RepoFileTreeSessionCache.swift
//  Starcat
//
//  文件树的进程内缓存。只存 Git Trees 响应，不存预览内容和勾选。
//
//  Sheet 每次打开都会 new 一个 ViewModel，没有这层缓存就会反复打 recursive tree。
//  树能从 GitHub 重建，不落库、不迁 schema；用户点刷新才重新拉。
//  key 带 ref：切分支互不影响。
//

import Foundation

actor RepoFileTreeSessionCache {
    static let shared = RepoFileTreeSessionCache()

    /// 扫描徽标和文件窗口可同时读取同一提交；每个消费者独立取消订阅。
    private struct Request {
        let id: UUID
        let task: Task<GitHubGitTreeDTO, Error>
        var consumers: Set<UUID>
    }

    private var trees: [String: GitHubGitTreeDTO] = [:]
    private var requests: [String: Request] = [:]
    private var generation: UInt64 = 0

    /// 在解析分支前捕获身份；切账号后才进入 load 的旧调用也必须失效。
    func currentGeneration() -> UInt64 { generation }

    /// 下载文件与 Skill 扫描共用这个入口；只缓存固定提交，并将凭据客户端纳入 key。
    func load(
        owner: String, repo: String, ref: String, scope: String,
        api: any GitHubAPIClientProtocol, force: Bool = false, expectedGeneration: UInt64? = nil
    ) async throws -> GitHubGitTreeDTO {
        try Task.checkCancellation()
        if let expectedGeneration, expectedGeneration != generation { throw CancellationError() }
        let scopedKey = scope + ":" + Self.key(owner: owner, repo: repo, ref: ref)
        if !force, let tree = trees[scopedKey] { return tree }
        let expected = generation
        let consumer = UUID()
        let request: Request
        if var existing = requests[scopedKey] {
            existing.consumers.insert(consumer)
            requests[scopedKey] = existing
            request = existing
        } else {
            let id = UUID()
            let task = Task {
                do {
                    let tree = try await api.repositoryGitTree(owner: owner, repo: repo, ref: ref)
                    try Task.checkCancellation()
                    guard self.generation == expected, self.requests[scopedKey]?.id == id else {
                        throw CancellationError()
                    }
                    if self.trees.count >= 24 { self.trees.removeAll() }
                    self.trees[scopedKey] = tree
                    self.requests[scopedKey] = nil
                    return tree
                } catch {
                    if self.requests[scopedKey]?.id == id { self.requests[scopedKey] = nil }
                    throw error
                }
            }
            request = Request(id: id, task: task, consumers: [consumer])
            requests[scopedKey] = request
        }
        // 取消只解除当前窗口的订阅；其它消费者仍在时不能取消共享的 URLSession 请求。
        return try await withTaskCancellationHandler {
            defer { release(consumer, key: scopedKey, requestID: request.id) }
            let tree = try await request.task.value
            try Task.checkCancellation()
            guard generation == expected else { throw CancellationError() }
            return tree
        } onCancel: {
            Task { await self.release(consumer, key: scopedKey, requestID: request.id) }
        }
    }

    private func release(_ consumer: UUID, key: String, requestID: UUID) {
        guard var request = requests[key], request.id == requestID else { return }
        request.consumers.remove(consumer)
        if request.consumers.isEmpty {
            requests[key] = nil
            request.task.cancel()
        } else {
            requests[key] = request
        }
    }

    /// 切账号先推进代际，旧请求即使迟到也不能重新填充私有缓存。
    func reset() {
        generation &+= 1
        requests.values.forEach { $0.task.cancel() }
        requests.removeAll()
        trees.removeAll()
    }

    func tree(owner: String, repo: String, ref: String) -> GitHubGitTreeDTO? {
        trees[Self.key(owner: owner, repo: repo, ref: ref)]
    }

    func store(_ dto: GitHubGitTreeDTO, owner: String, repo: String, ref: String) {
        trees[Self.key(owner: owner, repo: repo, ref: ref)] = dto
    }

    static func key(owner: String, repo: String, ref: String) -> String {
        "\(owner)/\(repo)#\(ref)"
    }
}
