//
//  CodebaseMemoryBinaryResolver.swift
//  Starcat
//
//  负责解析 bundle 内 Resources/codebase.bin 二进制。
//
//  为什么只执行 bundle 内资源：
//  1. App bundle 内资源随 Starcat 一起签名/打包,这是 sandbox 下最稳定的执行来源。
//  2. Xcode Run 环境下,运行时复制出来的 Mach-O 可能带 quarantine 且无法在 sandbox 内清理。
//  3. 用户可配置的 codebasememory 输出目录只存数据,不承担 executable cache 职责。
//
//  关键约束：
//  - 每次 Process spawn 前都走 resolveExecutable(),统一校验 bundle 内资源是否可执行。
//  - 只 spawn bundle 内可执行资源,避免运行时复制 Mach-O 后被 sandbox/quarantine 拦截。

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

    // MARK: - 核心入口

    /// 返回可执行二进制路径。
    ///
    /// `codebase.bin` 必须作为 App bundle 资源保持可执行。不要在运行时复制后再执行：
    /// Xcode sandbox 环境下复制副本可能被 quarantine / 执行策略拦截。
    ///
    /// - Throws: `CodebaseMemoryError.binaryMissing` 如果 bundle 内缺少二进制
    func resolveExecutable() throws -> URL {
        guard let bundleURL = bundleCodebaseURL else {
            DiagnosticLogStore.record(
                level: .critical,
                visibility: .issue,
                category: "codebase-memory",
                operation: "codebaseMemory.resolveBinary",
                message: "Bundled CodebaseMemory executable is missing"
            )
            throw CodebaseMemoryError.binaryMissing
        }

        if fileManager.isExecutableFile(atPath: bundleURL.path) {
            AppLog.ui.info("CodebaseMemory resolved bundle binary bundle=\(bundleURL.path, privacy: .public)")
            return bundleURL
        }

        let permissions = (try? fileManager.attributesOfItem(atPath: bundleURL.path)[.posixPermissions] as? Int) ?? 0
        AppLog.ui.error("CodebaseMemory bundle binary not executable bundle=\(bundleURL.path, privacy: .public) permissions=\(String(permissions, radix: 8), privacy: .public)")
        DiagnosticLogStore.record(
            level: .critical,
            visibility: .issue,
            category: "codebase-memory",
            operation: "codebaseMemory.resolveBinary",
            message: "Bundled CodebaseMemory executable is not executable",
            context: ["permissions": String(permissions, radix: 8)]
        )
        throw CodebaseMemoryError.binaryNotExecutable
    }
}
