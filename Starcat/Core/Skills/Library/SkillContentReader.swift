//
//  SkillContentReader.swift
//  Starcat
//
//  选中条目后才读取本机正文和文件目录。预览不执行附件、不访问远程资源，
//  不跟随内容中的符号链接；大小和遍历预算限制一次阅读的工作量。
//

import Foundation

/// 文件类型来自磁盘元数据，不能仅凭扩展名决定是否读取。
struct SkillContentFile: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case directory, file, symbolicLink, unsupported }
    let path: String
    let kind: Kind
    var id: String { path }
}

/// 正文与目录是一次后台读取的值快照，局部失败保留其他可读文件。
struct SkillContentSnapshot: Sendable {
    let rootPath: String
    let markdown: String
    let files: [SkillContentFile]
    let isPartial: Bool
}

/// 预览只接受有界 UTF-8 文本；二进制内容不交给系统插件或外部进程。
enum SkillContentPreview: Equatable, Sendable {
    case text(String), binary, tooLarge
}

/// 错误面向用户，具体文件路径由详情上下文提供，避免误称为一个正常空文件。
enum SkillContentReadError: LocalizedError {
    case unavailable, pathChanged, invalidPath, invalidManifest, tooLarge

    var errorDescription: String? {
        switch self {
        case .unavailable: String.l10n("skills.detail.content.unavailable")
        case .pathChanged: String.l10n("skills.detail.content.pathChanged")
        case .invalidPath: String.l10n("skills.detail.content.invalidPath")
        case .invalidManifest: String.l10n("skills.detail.content.encoding")
        case .tooLarge: String.l10n("skills.detail.files.tooLarge")
        }
    }
}

/// 无可变共享状态的后台读取器；执行层渠道检查先于任何目录访问。
struct SkillContentReader: Sendable {
    let maximumBytes: Int
    let maximumEntries: Int
    let maximumDepth: Int

    init(
        distributionGate: DistributionGate = DistributionGate(),
        maximumBytes: Int = 1_048_576,
        maximumEntries: Int = 2_000,
        maximumDepth: Int = 6
    ) throws {
        try distributionGate.requireDirect(.skillManagement)
        self.maximumBytes = max(1, maximumBytes)
        self.maximumEntries = max(1, maximumEntries)
        self.maximumDepth = max(1, maximumDepth)
    }

    /// 根来自已发现位置的 resolvedPath。目录被换成链接时要求重新扫描，不能自动换读别处。
    @concurrent
    func load(rootPath: String) async throws -> SkillContentSnapshot {
        try Task.checkCancellation()
        let root = try Self.validatedURL(rootPath: rootPath, relativePath: "")
        let manifest = try await preview(rootPath: root.path, relativePath: "SKILL.md")
        let markdown: String
        switch manifest {
        case .text(let text): markdown = text
        case .binary: throw SkillContentReadError.invalidManifest
        case .tooLarge: throw SkillContentReadError.tooLarge
        }
        var files: [SkillContentFile] = []
        var partial = false
        var pending: [(URL, String, Int)] = [(root, "", 0)]
        while let (directory, prefix, depth) = pending.popLast() {
            try Task.checkCancellation()
            let children: [URL]
            do {
                _ = try Self.validatedURL(rootPath: root.path, relativePath: prefix)
                children = try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [
                        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey
                    ]
                ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            } catch is CancellationError { throw CancellationError() }
            catch { partial = true; continue }
            for child in children {
                try Task.checkCancellation()
                guard files.count < maximumEntries else { partial = true; break }
                let path = prefix.isEmpty ? child.lastPathComponent : "\(prefix)/\(child.lastPathComponent)"
                do {
                    let values = try child.resourceValues(forKeys: [
                        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey
                    ])
                    let kind: SkillContentFile.Kind
                    if values.isSymbolicLink == true { kind = .symbolicLink }
                    else if values.isDirectory == true {
                        kind = .directory
                        if depth + 1 < maximumDepth { pending.append((child, path, depth + 1)) }
                        else { partial = true }
                    } else if values.isRegularFile == true { kind = .file }
                    else { kind = .unsupported }
                    files.append(SkillContentFile(path: path, kind: kind))
                } catch { partial = true }
            }
            if files.count >= maximumEntries, !pending.isEmpty { partial = true; break }
        }
        return SkillContentSnapshot(
            rootPath: root.path, markdown: markdown,
            files: files.sorted { $0.path < $1.path }, isPartial: partial
        )
    }

    /// 每次选择文件重新校验所有路径段；读取上限额外加一字节，避免仅依赖可变化的 fileSize。
    @concurrent
    func preview(rootPath: String, relativePath: String) async throws -> SkillContentPreview {
        try Task.checkCancellation()
        let url = try Self.validatedURL(rootPath: rootPath, relativePath: relativePath)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw SkillContentReadError.unavailable }
        if (values.fileSize ?? 0) > maximumBytes { return .tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        try Task.checkCancellation()
        guard bytes.count <= maximumBytes else { return .tooLarge }
        guard !bytes.contains(0), let text = String(data: bytes, encoding: .utf8) else { return .binary }
        return .text(text)
    }

    /// 仅接受相对路径，逐段拒绝附件链接；根本身必须仍是扫描时记录的物理目录。
    private static func validatedURL(rootPath: String, relativePath: String) throws -> URL {
        guard rootPath.hasPrefix("/"), !relativePath.hasPrefix("/") else {
            throw SkillContentReadError.invalidPath
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        if !relativePath.isEmpty, components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
            throw SkillContentReadError.invalidPath
        }
        var current = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        guard current.resolvingSymlinksInPath().path == current.path else {
            throw SkillContentReadError.pathChanged
        }
        let root = try current.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard root.isDirectory == true, root.isSymbolicLink != true else {
            throw SkillContentReadError.unavailable
        }
        for component in components where !component.isEmpty {
            current.appendPathComponent(String(component))
            let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw SkillContentReadError.pathChanged }
        }
        return current
    }
}
