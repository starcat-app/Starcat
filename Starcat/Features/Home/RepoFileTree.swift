//
//  RepoFileTree.swift
//  Starcat
//
//  把 GitHub recursive git tree 的扁平路径收成可勾选的嵌套节点。
//
//  为什么单独抽文件：
//  - 树构建、勾选传播、路径穿越防护都不依赖 SwiftUI，必须能单测；
//  - 子模块 / 符号链接不能当普通文件下，否则会把 pointer 或空 blob 写成「源码」。
//

import Foundation

/// Sheet 打开时锁定的仓库身份。每次点击菜单都新建一份，避免复用上一次的勾选。
struct RepoFileBrowserTarget: Equatable, Sendable {
    let owner: String
    let name: String
    let fullName: String
    /// git trees 的 ref：默认分支，缺失时用 `HEAD`。
    let ref: String
    /// 顶栏仓库简介；Trending / 缓存缺字段时为 nil。
    let summary: String?
    let isPrivate: Bool
    /// 顶栏 owner 头像；来源模型缺字段时为 nil，由 Sheet 兜底拼 `github.com/{owner}.png`。
    let ownerAvatar: String?

    init(
        owner: String,
        name: String,
        fullName: String,
        ref: String,
        summary: String? = nil,
        isPrivate: Bool = false,
        ownerAvatar: String? = nil
    ) {
        self.owner = owner
        self.name = name
        self.fullName = fullName
        self.ref = ref
        self.summary = summary
        self.isPrivate = isPrivate
        self.ownerAvatar = ownerAvatar
    }
}

/// 文件树行、预览 header、右侧详情三处共用的「文件名 → SF Symbol」映射。
///
/// 为什么只做纯 Source 映射：不渲染视图，单测直接断言 iconSource；
/// 图标颜色统一交给调用方维持 `.secondary` 单色，符合 UI 颜色规范。
/// macOS 的 `pathExtension` 会把 `.gitignore` 这类 dotfile 判成无扩展名，
/// 所以手动按最后一个 `.` 切，点号在最前时整名当作扩展名 key。
enum RepoFileTypeIcon {

    static func iconSource(forFileName name: String) -> BusinessIcon.Source {
        let lowered = name.lowercased()
        if let dot = lowered.lastIndex(of: ".") {
            let ext = lowered[lowered.index(after: dot)...]
            if let symbol = byExtension[String(ext)] { return symbol }
        }
        return byBareName[lowered] ?? .business(.file)
    }

    private static let code = BusinessIcon.Source.business(.codeContext)

    private static let byExtension: [String: BusinessIcon.Source] = [
        // 文档
        "md": .business(.file), "markdown": .business(.file), "txt": .business(.file),
        "rtf": .business(.file), "rst": .business(.file), "adoc": .business(.file), "pdf": .business(.file),
        // 代码与配置
        "swift": code, "py": code, "js": code, "jsx": code, "ts": code, "tsx": code,
        "go": code, "rs": code, "rb": code, "php": code, "java": code, "kt": code, "kts": code,
        "c": code, "h": code, "cpp": code, "hpp": code, "cc": code, "cs": code, "m": code, "mm": code,
        "sh": code, "bash": code, "zsh": code, "fish": code, "ps1": code, "lua": code, "sql": code,
        "dart": code, "scala": code, "ex": code, "exs": code, "hs": code, "erl": code,
        "vue": code, "svelte": code, "r": code, "jl": code, "vim": code,
        "json": code, "yaml": code, "yml": code, "toml": code, "xml": code,
        "html": code, "css": code, "scss": code, "less": code, "ini": code,
        "cfg": code, "conf": code, "env": code, "lock": code, "proto": code, "graphql": code,
        "gitignore": code, "gitattributes": code, "editorconfig": code, "dockerignore": code,
        // 图片
        "png": .business(.image), "jpg": .business(.image), "jpeg": .business(.image), "gif": .business(.image),
        "webp": .business(.image), "svg": .business(.image), "ico": .business(.image), "bmp": .business(.image),
        "tiff": .business(.image), "heic": .business(.image), "avif": .business(.image),
        // 压缩包
        "zip": .business(.fileArchive), "tar": .business(.fileArchive), "gz": .business(.fileArchive), "tgz": .business(.fileArchive),
        "bz2": .business(.fileArchive), "xz": .business(.fileArchive), "7z": .business(.fileArchive), "rar": .business(.fileArchive),
        // 音频
        "mp3": .business(.audio), "wav": .business(.audio), "aac": .business(.audio),
        "flac": .business(.audio), "ogg": .business(.audio), "m4a": .business(.audio),
        // 视频
        "mp4": .business(.video), "mov": .business(.video), "avi": .business(.video), "mkv": .business(.video), "webm": .business(.video), "m4v": .business(.video),
    ]

    /// 无扩展名的常见仓库文件（LICENSE / Makefile 这类），按整名匹配。
    private static let byBareName: [String: BusinessIcon.Source] = [
        "dockerfile": code,
        "makefile": code,
        "license": .business(.file),
        "licence": .business(.file),
        "readme": .business(.file),
        "changelog": .business(.file),
    ]
}

/// 树上的一个可见节点。文件的 `children` 为 nil；目录即使为空也是 `[]`。
struct RepoFileNode: Identifiable, Equatable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    let isDirectory: Bool
    let blobSHA: String?
    let size: Int?
    let children: [RepoFileNode]?
}

enum RepoFileCheckState: Equatable, Sendable {
    case off
    case mixed
    case on
}

enum RepoFileTreeBuilder {

    /// 从 GitHub tree 条目生成根节点。跳过子模块、符号链接和含 `..` 的路径。
    static func build(from entries: [GitHubGitTreeEntryDTO]) -> [RepoFileNode] {
        let root = DirectoryDraft(name: "", path: "")

        for entry in entries {
            guard isSafeRelativePath(entry.path) else { continue }
            if isSkipped(entry) { continue }

            if entry.type == "tree" || entry.mode == "040000" {
                root.ensureDirectory(at: entry.path)
            } else if entry.type == "blob" {
                root.insertFile(
                    path: entry.path,
                    sha: entry.sha,
                    size: entry.size
                )
            }
        }

        return root.makeNode().children ?? []
    }

    /// 该节点（含子孙）所有可下载文件的 path。
    static func descendantFilePaths(of node: RepoFileNode) -> [String] {
        if !node.isDirectory {
            return node.blobSHA == nil ? [] : [node.path]
        }
        return (node.children ?? []).flatMap(descendantFilePaths(of:))
    }

    static func checkState(of node: RepoFileNode, selected: Set<String>) -> RepoFileCheckState {
        let paths = descendantFilePaths(of: node)
        guard !paths.isEmpty else { return .off }
        let selectedCount = paths.reduce(into: 0) { count, path in
            if selected.contains(path) { count += 1 }
        }
        if selectedCount == 0 { return .off }
        if selectedCount == paths.count { return .on }
        return .mixed
    }

    /// 点文件夹：全选或全不选其下文件。点文件：只翻转自己。
    static func toggle(_ node: RepoFileNode, in selected: inout Set<String>) {
        let paths = descendantFilePaths(of: node)
        guard !paths.isEmpty else { return }
        if checkState(of: node, selected: selected) == .on {
            selected.subtract(paths)
        } else {
            selected.formUnion(paths)
        }
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return false }
        return !trimmed.split(separator: "/").contains { $0 == ".." || $0 == "." }
    }

    /// 路径或文件名包含 query 的子树。目录名命中时保留其下全部文件，方便按文件夹搜。
    static func filtered(_ nodes: [RepoFileNode], matching query: String) -> [RepoFileNode] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nodes }
        return nodes.compactMap { filter($0, matching: needle) }
    }

    private static func filter(_ node: RepoFileNode, matching query: String) -> RepoFileNode? {
        let selfMatches = node.name.localizedCaseInsensitiveContains(query)
            || node.path.localizedCaseInsensitiveContains(query)
        if node.isDirectory {
            if selfMatches {
                return node
            }
            let children = (node.children ?? []).compactMap { filter($0, matching: query) }
            guard !children.isEmpty else { return nil }
            return RepoFileNode(
                name: node.name,
                path: node.path,
                isDirectory: true,
                blobSHA: nil,
                size: nil,
                children: children
            )
        }
        return selfMatches ? node : nil
    }

    /// Folders 页只留目录，方便按目录浏览；空目录也保留。
    static func foldersOnly(_ nodes: [RepoFileNode]) -> [RepoFileNode] {
        nodes.compactMap { node in
            guard node.isDirectory else { return nil }
            return RepoFileNode(
                name: node.name,
                path: node.path,
                isDirectory: true,
                blobSHA: nil,
                size: nil,
                children: foldersOnly(node.children ?? [])
            )
        }
    }

    static func find(path: String, in nodes: [RepoFileNode]) -> RepoFileNode? {
        for node in nodes {
            if node.path == path { return node }
            if let children = node.children, let found = find(path: path, in: children) {
                return found
            }
        }
        return nil
    }

    private static func isSkipped(_ entry: GitHubGitTreeEntryDTO) -> Bool {
        entry.type == "commit"
            || entry.mode == "160000"
            || entry.mode == "120000"
    }
}

/// 构建期可变目录。用 class 是为了按路径逐级挂子节点，避免反复拷贝整棵 struct。
private final class DirectoryDraft {
    let name: String
    let path: String
    var files: [FileDraft] = []
    var directories: [String: DirectoryDraft] = [:]

    init(name: String, path: String) {
        self.name = name
        self.path = path
    }

    func ensureDirectory(at path: String) {
        _ = directory(at: path)
    }

    func insertFile(path: String, sha: String, size: Int?) {
        let parts = path.split(separator: "/").map(String.init)
        guard let fileName = parts.last else { return }
        let parent: DirectoryDraft
        if parts.count == 1 {
            parent = self
        } else {
            parent = directory(at: parts.dropLast().joined(separator: "/"))
        }
        if parent.files.contains(where: { $0.path == path }) { return }
        parent.files.append(FileDraft(name: fileName, path: path, sha: sha, size: size))
    }

    func makeNode() -> RepoFileNode {
        let childDirs = directories.values
            .map { $0.makeNode() }
            .sorted(by: Self.nodeSort)
        let childFiles = files
            .map { file in
                RepoFileNode(
                    name: file.name,
                    path: file.path,
                    isDirectory: false,
                    blobSHA: file.sha,
                    size: file.size,
                    children: nil
                )
            }
            .sorted(by: Self.nodeSort)
        return RepoFileNode(
            name: name,
            path: path,
            isDirectory: true,
            blobSHA: nil,
            size: nil,
            children: childDirs + childFiles
        )
    }

    private func directory(at path: String) -> DirectoryDraft {
        var current = self
        var assembled: [String] = []
        for part in path.split(separator: "/").map(String.init) where !part.isEmpty {
            assembled.append(part)
            let childPath = assembled.joined(separator: "/")
            if let existing = current.directories[part] {
                current = existing
            } else {
                let created = DirectoryDraft(name: part, path: childPath)
                current.directories[part] = created
                current = created
            }
        }
        return current
    }

    private static func nodeSort(_ lhs: RepoFileNode, _ rhs: RepoFileNode) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory && !rhs.isDirectory
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

private struct FileDraft {
    let name: String
    let path: String
    let sha: String
    let size: Int?
}
