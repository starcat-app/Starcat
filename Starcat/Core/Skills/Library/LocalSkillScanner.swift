//
//  LocalSkillScanner.swift
//  Starcat
//
//  有界、只读的本机发现。每根单独报告覆盖状态；取消、权限失败和截断
//  不得伪装成完整空结果，也不执行 Skill 或递归跟随其附件链接。
//

import Darwin
import Foundation

/// 预算限制检查工作量；文件读取还有单独字节上限，不把整个文件无界加载到内存。
struct SkillScanLimits: Sendable {
    var maxDepth = 6
    var maxDirectories = 5_000
    var maxEntries = 50_000
    var maxManifestBytes = 1_048_576
}

struct SkillScanRequest: Sendable {
    let generationID: UUID
    let roots: [SkillLibraryRoot]
    var limits = SkillScanLimits()
}

/// 路径是发现证据，不是写入授权；无法解析时仍保留候选及诊断。
struct SkillScanCandidate: Sendable {
    let lexicalPath: String
    let resolvedPath: String
    let kind: SkillLibraryLocationKind
    let metadata: SkillFrontmatter.Metadata?
    let diagnostic: String?
}

struct SkillRootScanResult: Sendable {
    let root: SkillLibraryRoot
    let resolvedPath: String?
    let coverage: SkillScanCoverage
    let candidates: [SkillScanCandidate]
    let diagnostics: [String]
    let directoryCount: Int
    let entryCount: Int
}

struct SkillScanReport: Sendable {
    let generationID: UUID
    let results: [SkillRootScanResult]
}

/// 一次最多四个根；同步文件操作在明确的 concurrent executor 上运行。
struct LocalSkillScanner: Sendable {
    init(distributionGate: DistributionGate = DistributionGate()) throws {
        try distributionGate.requireDirect(.skillManagement)
    }

    @concurrent
    func scan(_ request: SkillScanRequest) async -> SkillScanReport {
        await withTaskGroup(of: SkillRootScanResult.self) { group in
            var iterator = request.roots.makeIterator()
            for _ in 0..<min(4, request.roots.count) {
                if let root = iterator.next() {
                    group.addTask { Self.scanRoot(root, limits: request.limits) }
                }
            }
            var results: [SkillRootScanResult] = []
            for await result in group {
                results.append(result)
                if let root = iterator.next() {
                    group.addTask { Self.scanRoot(root, limits: request.limits) }
                }
            }
            return SkillScanReport(
                generationID: request.generationID,
                results: results.sorted { $0.root.configuredPath < $1.root.configuredPath }
            )
        }
    }

    /// ancestors 按当前分支记录：阻断循环，同时保留两个词法入口到同一物理 Skill 的证据。
    private static func scanRoot(_ root: SkillLibraryRoot, limits: SkillScanLimits) -> SkillRootScanResult {
        let manager = FileManager.default
        let rootURL = URL(fileURLWithPath: root.configuredPath, isDirectory: true)
        var coverage: SkillScanCoverage = .complete
        var diagnostics: [String] = []
        var candidates: [SkillScanCandidate] = []
        var directoryCount = 0
        var entryCount = 0
        var resolvedRoot: String?
        var pending: [(url: URL, depth: Int, ancestors: Set<String>)] = [(rootURL, 0, [])]

        while let node = pending.popLast() {
            if Task.isCancelled { coverage = .cancelled; break }
            guard directoryCount < max(0, limits.maxDirectories) else {
                coverage = .partial
                diagnostics.append("Directory budget exceeded")
                break
            }
            directoryCount += 1
            do {
                let attributes = try manager.attributesOfItem(atPath: node.url.path)
                let kind = attributes[.type] as? FileAttributeType
                let resolved = node.url.resolvingSymlinksInPath().standardizedFileURL
                if node.depth == 0 { resolvedRoot = resolved.path }
                guard !node.ancestors.contains(resolved.path) else {
                    coverage = .partial
                    diagnostics.append("\(node.url.path): symbolic link cycle")
                    continue
                }
                let resolvedAttributes = try manager.attributesOfItem(atPath: resolved.path)
                guard resolvedAttributes[.type] as? FileAttributeType == .typeDirectory else {
                    if node.depth == 0 {
                        coverage = resolvedAttributes[.type] as? FileAttributeType == .typeSymbolicLink
                            ? .unavailable : .unsupported
                        diagnostics.append("\(node.url.path): root is not a directory")
                    } else if resolvedAttributes[.type] as? FileAttributeType == .typeSymbolicLink {
                        coverage = .partial
                        diagnostics.append("\(node.url.path): unresolved symbolic link")
                    }
                    continue
                }
                let manifest = node.url.appendingPathComponent("SKILL.md")
                let manifestAttributes: [FileAttributeKey: Any]?
                do {
                    manifestAttributes = try manager.attributesOfItem(atPath: manifest.path)
                } catch where isMissing(error) {
                    manifestAttributes = nil
                }
                if let manifestAttributes {
                    var metadata: SkillFrontmatter.Metadata?
                    var diagnostic: String?
                    if manifestAttributes[.type] as? FileAttributeType != .typeRegular {
                        diagnostic = "SKILL.md: not a regular file"
                    } else {
                        do {
                            let handle = try FileHandle(forReadingFrom: manifest)
                            defer { try? handle.close() }
                            let data = try handle.read(upToCount: max(0, limits.maxManifestBytes) + 1) ?? Data()
                            guard data.count <= max(0, limits.maxManifestBytes) else {
                                throw CocoaError(.fileReadTooLarge)
                            }
                            if let markdown = String(data: data, encoding: .utf8) {
                                do {
                                    metadata = try SkillFrontmatter.parse(markdown, directory: "")
                                } catch {
                                    // 现有 parser 是 YAML 子集；不能把不支持语法一律声称为非法 YAML。
                                    diagnostic = "SKILL.md: invalid or unsupported frontmatter"
                                }
                            } else {
                                diagnostic = "SKILL.md: expected UTF-8"
                            }
                        } catch {
                            coverage = .partial
                            diagnostic = "SKILL.md: \(error.localizedDescription)"
                        }
                    }
                    candidates.append(SkillScanCandidate(
                        lexicalPath: node.url.standardizedFileURL.path, resolvedPath: resolved.path,
                        kind: kind == .typeSymbolicLink ? .symbolicLink : .directory,
                        metadata: metadata, diagnostic: diagnostic
                    ))
                    // 找到 Skill 就停止深入，references 内的示例不应成为另一份安装。
                    continue
                }
                let children = try manager.contentsOfDirectory(
                    at: node.url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                ).sorted { $0.lastPathComponent < $1.lastPathComponent }
                var ancestors = node.ancestors
                ancestors.insert(resolved.path)
                for child in children {
                    if Task.isCancelled { coverage = .cancelled; break }
                    guard entryCount < max(0, limits.maxEntries) else {
                        coverage = .partial
                        diagnostics.append("Entry budget exceeded")
                        break
                    }
                    entryCount += 1
                    let childKind = try manager.attributesOfItem(atPath: child.path)[.type] as? FileAttributeType
                    if childKind == .typeDirectory || childKind == .typeSymbolicLink {
                        if node.depth >= max(0, limits.maxDepth) {
                            coverage = .partial
                            diagnostics.append("\(child.path): depth budget exceeded")
                        } else {
                            pending.append((child, node.depth + 1, ancestors))
                        }
                    } else if node.depth == 0, child.pathExtension.lowercased() == "md",
                              root.agentIDs.contains(RepoSkillTargetPreset.openCode.rawValue) {
                        coverage = .partial
                        diagnostics.append("\(child.path): standalone Markdown Skills are not indexed")
                    }
                }
                if entryCount >= max(0, limits.maxEntries), !pending.isEmpty {
                    coverage = .partial
                    diagnostics.append("Entry budget exceeded before queued directories were inspected")
                    break
                }
            } catch {
                let state = node.depth == 0 ? rootFailure(error, at: rootURL) : .partial
                coverage = state
                if state != .missing { diagnostics.append("\(node.url.path): \(error.localizedDescription)") }
            }
        }
        return SkillRootScanResult(
            root: root, resolvedPath: resolvedRoot, coverage: coverage, candidates: candidates,
            diagnostics: Array(diagnostics.prefix(50)), directoryCount: directoryCount, entryCount: entryCount
        )
    }

    private static func isMissing(_ error: any Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileReadNoSuchFile.rawValue)
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }

    /// 缺失必须有可读取父目录的证据；外置卷离线不能当成用户删除所有 Skill。
    private static func rootFailure(_ error: any Error, at url: URL) -> SkillScanCoverage {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.fileReadNoPermission.rawValue {
            return .inaccessible
        }
        guard isMissing(error) else { return .unavailable }
        if url.path.hasPrefix("/Volumes/") { return .unavailable }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink { return .unavailable }
        var parent = url.deletingLastPathComponent()
        while parent.path != "/" {
            if access(parent.path, R_OK | X_OK) == 0 { return .missing }
            if access(parent.path, F_OK) == 0 { return .inaccessible }
            parent = parent.deletingLastPathComponent()
        }
        return access("/", R_OK | X_OK) == 0 ? .missing : .unavailable
    }
}
