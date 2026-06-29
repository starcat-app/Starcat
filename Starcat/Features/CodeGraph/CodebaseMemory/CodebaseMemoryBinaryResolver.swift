//
//  CodebaseMemoryBinaryResolver.swift
//  Starcat
//
//  负责解析 bundle 内 Resources/codebase.bin 二进制；仅在 bundle 资源不可执行时,
//  才 lazy 拷贝到 App 自己可控的 Application Support 缓存目录作为 fallback。
//
//  为什么需要拷贝：
//  1. App bundle 内资源随 Starcat 一起签名/打包,这是 sandbox 下最稳定的执行来源。
//  2. Process spawn 要求可执行文件带 +x, 否则 fileIsNotExecutable。
//  3. 用户可配置的 codebasememory 输出目录只存数据,不承担 executable cache 职责。
//
//  关键约束：
//  - 每次 Process spawn 前都走 resolveExecutable() ——首次调用做拷贝+chmod,后续直接返回
//  - 优先 spawn bundle 内可执行资源,避免运行时复制 Mach-O 后被 sandbox/quarantine 拦截
//  - fallback cache 不跟随用户输出目录迁移/清空;它是 App 内置工具缓存,不是项目数据
//  - fallback 复制后尝试移除 quarantine xattr,失败只记录日志,不掩盖真正执行性检查

import Darwin
import Foundation

actor CodebaseMemoryBinaryResolver {

    private let fileManager: FileManager

    /// 供单测注入 mock 路径。
    var fixedBundleCodebaseURL: URL?

    init(
        storage _: CodebaseMemoryStorage,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
    }

    // MARK: - Bundle 内资源路径

    /// `Starcat.app/Contents/Resources/codebase.bin`
    /// Xcode 拍平 Resources 子目录，文件直接位于 Resources 根，无 Codebase/ 子目录。
    private var bundleCodebaseURL: URL? {
        if let fixed = fixedBundleCodebaseURL { return fixed }
        return Bundle.main.url(
            forResource: "codebase",
            withExtension: "bin",
            subdirectory: nil
        )
    }

    // MARK: - App 内部可执行缓存路径

    /// fallback: `Application Support/Starcat/CodebaseMemory/bin/codebase`
    ///
    /// fallback 也故意不放在用户选择的 codebasememory 输出目录下。输出目录通过
    /// security-scoped bookmark 访问,适合存项目数据和 DB,不适合作为可执行文件缓存。
    func containerCodebaseURL() throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Starcat/CodebaseMemory/bin/codebase", isDirectory: false)
    }

    // MARK: - 核心入口

    /// 返回可执行二进制路径。
    ///
    /// - 首选: bundle 内 `codebase.bin` 已可执行 → 直接返回 bundle 路径
    /// - fallback: bundle 不可执行 → 拷贝到 App Support + chmod 0755
    ///
    /// - Throws: `CodebaseMemoryError.binaryMissing` 如果 bundle 内缺少二进制
    func resolveExecutable() throws -> URL {
        guard let bundleURL = bundleCodebaseURL else {
            throw CodebaseMemoryError.binaryMissing
        }

        if fileManager.isExecutableFile(atPath: bundleURL.path) {
            AppLog.ui.info("CodebaseMemory resolved bundle binary bundle=\(bundleURL.path, privacy: .public)")
            return bundleURL
        }

        let containerURL = try containerCodebaseURL()
        AppLog.ui.info("CodebaseMemory resolve binary bundle=\(bundleURL.path, privacy: .public) target=\(containerURL.path, privacy: .public)")

        // 比较 bundle 与 container 的文件大小，不同则重新拷贝（支持二进制更新）
        let bundleSize = (try? fileManager.attributesOfItem(atPath: bundleURL.path)[.size] as? Int) ?? 0
        let containerSize: Int
        if fileManager.fileExists(atPath: containerURL.path) {
            containerSize = (try? fileManager.attributesOfItem(atPath: containerURL.path)[.size] as? Int) ?? 0
        } else {
            containerSize = -1
        }

        if containerSize == bundleSize, fileManager.isExecutableFile(atPath: containerURL.path) {
            removeQuarantineIfNeeded(at: containerURL)
            AppLog.ui.info("CodebaseMemory resolved cached binary target=\(containerURL.path, privacy: .public)")
            return containerURL
        }

        // 大小不匹配或不可执行 → 重新从 bundle 拷贝

        // 确保 .bin/ 父目录存在
        try fileManager.createDirectory(
            at: containerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // 覆盖旧副本（如有）
        if fileManager.fileExists(atPath: containerURL.path) {
            try fileManager.removeItem(at: containerURL)
        }
        try fileManager.copyItem(at: bundleURL, to: containerURL)

        // 显式 chmod —— bundle 内资源被 Xcode strip 了 x 权限
        var currentAttrs = (try? fileManager.attributesOfItem(atPath: containerURL.path))
            ?? [:]
        currentAttrs[.posixPermissions] = 0o755
        try fileManager.setAttributes(currentAttrs, ofItemAtPath: containerURL.path)

        // 兜底：用 chmod 再设一次（POSIX 层确保无遗漏）
        let currentPerms = (try? fileManager.attributesOfItem(atPath: containerURL.path))?[.posixPermissions] as? Int ?? 0
        if currentPerms & 0o111 == 0 {
            // 直接系统调用兜底
            chmod(containerURL.path, 0o755)
        }
        removeQuarantineIfNeeded(at: containerURL)

        guard fileManager.isExecutableFile(atPath: containerURL.path) else {
            let permissions = (try? fileManager.attributesOfItem(atPath: containerURL.path)[.posixPermissions] as? Int) ?? 0
            AppLog.ui.error("CodebaseMemory binary not executable target=\(containerURL.path, privacy: .public) permissions=\(String(permissions, radix: 8), privacy: .public)")
            throw CodebaseMemoryError.binaryNotExecutable
        }

        AppLog.ui.info("CodebaseMemory resolved fresh binary target=\(containerURL.path, privacy: .public)")
        return containerURL
    }

    private func removeQuarantineIfNeeded(at url: URL) {
        let result = url.path.withCString { pathPointer in
            removexattr(pathPointer, "com.apple.quarantine", 0)
        }
        if result == 0 {
            AppLog.ui.info("CodebaseMemory removed quarantine xattr target=\(url.path, privacy: .public)")
        } else if errno != ENOATTR {
            AppLog.ui.error("CodebaseMemory quarantine xattr remove failed target=\(url.path, privacy: .public) errno=\(errno, privacy: .public)")
        }
    }
}
