//
//  SkillRootWatcher.swift
//  Starcat
//
//  FSEvents 只发出对账提示，不直接修改索引。递归事件、事件丢失和根变化
//  都触发受控重扫；回调不读取文件正文，也不持久化事件路径。
//

import CoreServices
import Foundation

protocol SkillRootWatching: Sendable {
    func start(paths: [String], onChange: @escaping @Sendable () -> Void) async throws
    func stop()
}

/// C stream 没有 Sendable 声明；所有 stream 生命周期操作由 lock 串行保护。
/// 回调上下文由 FSEvents retain/release 配对持有，避免停窗时悬空或重复释放。
final class SkillRootWatcher: SkillRootWatching, @unchecked Sendable {
    private let lock = NSLock()
    private let callbackQueue = DispatchQueue(label: "com.starcat.skills.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?

    init(distributionGate: DistributionGate = DistributionGate()) throws {
        try distributionGate.requireDirect(.skillManagement)
    }

    @concurrent
    func start(paths: [String], onChange: @escaping @Sendable () -> Void) async throws {
        try startSynchronously(paths: paths, onChange: onChange)
    }

    /// 回调只安排异步刷新，不得从回调内同步重入 start／stop。
    private func startSynchronously(paths: [String], onChange: @escaping @Sendable () -> Void) throws {
        try Task.checkCancellation()
        // 监听父目录以发现根的创建／替换，但只接受逻辑根和实际内容内的事件；
        // 尤其不能让独立库 SQLite 写入不断触发对 managed 根的自刷新。
        let interesting = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let available = Self.availableDirectories(for: interesting)
        // 元数据探测在锁外，关闭窗口不必等待文件系统；取消请求不能先停掉新会话的 stream。
        lock.lock()
        defer { lock.unlock() }
        try Task.checkCancellation()
        stopLocked()
        guard !available.isEmpty else { return }
        let handler = Handler(paths: interesting, onChange: onChange)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<Handler>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<Handler>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let created = FSEventStreamCreate(
            nil,
            { _, pointer, count, eventPaths, eventFlags, _ in
                guard let pointer else { return }
                let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
                Unmanaged<Handler>.fromOpaque(pointer).takeUnretainedValue().receive(
                    paths: paths, flags: UnsafeBufferPointer(start: eventFlags, count: count)
                )
            },
            &context, available as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags
        ) else { throw CocoaError(.fileReadUnknown) }
        FSEventStreamSetDispatchQueue(created, callbackQueue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            throw CocoaError(.fileReadUnknown)
        }
        stream = created
    }

    /// fileExists 只用于选监听句柄，绝不据此认定位置消失；缺失根由 scanner 和补扫确认。
    private static func availableDirectories(for paths: Set<String>) -> [String] {
        let manager = FileManager.default
        var directories: Set<String> = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            for candidate in [url, url.deletingLastPathComponent()] {
                var isDirectory: ObjCBool = false
                if manager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    directories.insert(candidate.path)
                }
            }
        }
        var result: [String] = []
        for path in directories.sorted(by: { $0.count < $1.count }) {
            if !result.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { result.append(path) }
        }
        return result
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    deinit { stop() }

    /// 不含可变状态；系统回调可以安全读取并调用 Sendable 闭包。
    private final class Handler: Sendable {
        let paths: Set<String>
        let onChange: @Sendable () -> Void
        init(paths: Set<String>, onChange: @escaping @Sendable () -> Void) {
            self.paths = paths
            self.onChange = onChange
        }

        /// 丢事件或根变化需要完整对账；普通事件过滤邻接目录，C buffer 不逃出回调。
        func receive(paths changed: [String], flags: UnsafeBufferPointer<FSEventStreamEventFlags>) {
            let reconcile = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
                    | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount
            )
            let relevant = changed.contains { path in
                paths.contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
            }
            if relevant || flags.contains(where: { $0 & reconcile != 0 }) { onChange() }
        }
    }
}
