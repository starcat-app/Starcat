//
//  CodebaseMemoryBinaryResolver.swift
//  Starcat
//
//  负责把 bundle 内 Resources/Codebase/codebase 二进制 lazy 拷贝到
//  sandbox container `<codebasememory-root>/.bin/codebase` 并设置可执行权限。
//
//  为什么需要拷贝：
//  1. Xcode 打包时 strip 所有 bundle 资源文件的 +x 权限（即使脚本里已设 chmod 0755）
//  2. Process spawn 要求可执行文件带 +x, 否则 fileIsNotExecutable
//  3. container 副本只在 .bin/ 下, 不占额外目录污染
//
//  关键约束：
//  - 每次 Process spawn 前都走 resolveExecutable() ——首次调用做拷贝+chmod,后续直接返回
//  - 永远不 spawn bundle 内未 chmod 的资源文件

import Foundation

actor CodebaseMemoryBinaryResolver {

    private let storage: CodebaseMemoryStorage
    private let fileManager: FileManager

    /// 供单测注入 mock 路径。
    var fixedBundleCodebaseURL: URL?

    init(
        storage: CodebaseMemoryStorage,
        fileManager: FileManager = .default
    ) {
        self.storage = storage
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

    // MARK: - Container 内副本路径

    /// `<codebasememory-root>/.bin/codebase`
    func containerCodebaseURL() throws -> URL {
        try storage.outputRootURL()
            .appendingPathComponent(".bin/codebase", isDirectory: false)
    }

    // MARK: - 核心入口

    /// 返回 container 内已 chmod +x 的二进制路径。
    ///
    /// - 首次调用: 从 bundle 拷贝 + 显式 chmod 0755 + 最终兜底硬设
    /// - 后续调用: 检测文件已可执行 → 直接返回
    ///
    /// - Throws: `CodebaseMemoryError.binaryMissing` 如果 bundle 内缺少二进制
    func resolveExecutable() throws -> URL {
        let containerURL = try containerCodebaseURL()

        guard let bundleURL = bundleCodebaseURL else {
            throw CodebaseMemoryError.binaryMissing
        }

        // 比较 bundle 与 container 的文件大小，不同则重新拷贝（支持二进制更新）
        let bundleSize = (try? fileManager.attributesOfItem(atPath: bundleURL.path)[.size] as? Int) ?? 0
        let containerSize: Int
        if fileManager.fileExists(atPath: containerURL.path) {
            containerSize = (try? fileManager.attributesOfItem(atPath: containerURL.path)[.size] as? Int) ?? 0
        } else {
            containerSize = -1
        }

        if containerSize == bundleSize, fileManager.isExecutableFile(atPath: containerURL.path) {
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

        guard fileManager.isExecutableFile(atPath: containerURL.path) else {
            throw CodebaseMemoryError.binaryNotExecutable
        }

        return containerURL
    }
}
