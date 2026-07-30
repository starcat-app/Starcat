//
//  WikiAvailabilitySnapshotLoader.swift
//  Starcat
//
//  Repo List 的 Wiki availability 批量只读加载器。
//
//  列表筛选可能一次检查几十到上千个本地 JSON。DiskWikiCache 是 @MainActor 的设置页/CRUD
//  事实源，逐条调用它的同步 load 会把文件 IO 和 JSON decode 全部压在主线程，直接冻结窗口动画。
//  本加载器把批量读盘放进 detached task，并只向主线程返回轻量 id→Bool 快照。
//

import Foundation
import Darwin

/// 一条 Wiki availability 读取请求。
struct WikiAvailabilityRequest: Sendable, Equatable {
    let id: Int64
    let owner: String
    let repo: String
}

/// 批量读取 Wiki 缓存的无状态服务。
enum WikiAvailabilitySnapshotLoader {

    /// 返回“已经探测过”的 repo availability；不存在或损坏的文件不进入结果字典。
    ///
    /// 缺失 key 表示 unknown，调用方不能把它当成 missing。`rootOverride` 只用于单测隔离，
    /// 生产默认读取 `Application Support/<bundle>/wiki-cache/`。
    static func load(
        requests: [WikiAvailabilityRequest],
        rootOverride: URL? = nil,
        readObserverForTesting: (@Sendable (_ isMainThread: Bool) -> Void)? = nil
    ) async -> [Int64: Bool] {
        guard !requests.isEmpty else { return [:] }

        let task: Task<[Int64: Bool], Never> = Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let root: URL
            if let rootOverride {
                root = rootOverride
            } else {
                guard let appSupport = fileManager.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first else { return [:] }
                root = appSupport
                    .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
                    .appendingPathComponent("wiki-cache", isDirectory: true)
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var availability: [Int64: Bool] = [:]
            availability.reserveCapacity(requests.count)

            for request in requests {
                guard !Task.isCancelled else { return [:] }
                guard (try? DiskWikiCache.assertSafePathComponent(request.owner)) != nil,
                      (try? DiskWikiCache.assertSafePathComponent(request.repo)) != nil else { continue }
                let url = root
                    .appendingPathComponent(request.owner, isDirectory: true)
                    .appendingPathComponent("\(request.repo).json")
                // Swift 6 禁止在 async context 读取 Thread.isMainThread；pthread_main_np 是
                // macOS 原生的只读线程判定，测试只用它证明 Data(contentsOf:) 不在主线程。
                readObserverForTesting?(pthread_main_np() != 0)
                guard let data = try? Data(contentsOf: url),
                      let snapshot = try? decoder.decode(WikiCacheSnapshot.self, from: data) else {
                    continue
                }
                availability[request.id] = !snapshot.indexedLinks.isEmpty
            }
            return availability
        }
        return await withTaskCancellationHandler(
            operation: {
                await PerformanceTracer.shared.trace(.wikiAvailabilityLoad, task: task)
            },
            onCancel: {
                // detached task 不会自动继承调用方的取消；显式传播，避免旧分类继续占用磁盘与 CPU。
                task.cancel()
            }
        )
    }
}
