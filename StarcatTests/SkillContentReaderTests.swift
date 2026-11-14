//
//  SkillContentReaderTests.swift
//  StarcatTests
//
//  仅使用临时目录验证真实文件读取、预算与链接边界，不扫描本机 Agent 目录。
//

import Foundation
import Testing
@testable import Starcat

struct SkillContentReaderTests {
    @Test("App Store 在访问目录前拒绝构造")
    func rejectsAppStore() {
        #expect(throws: (any Error).self) {
            try SkillContentReader(distributionGate: DistributionGate(channel: .appStore))
        }
    }

    @Test("读取完整正文与相对文件目录，刷新反映磁盘变化")
    func readsContentAndChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("references/guide.md", text: "说明")
        let reader = try Fixture.reader()
        let content = try await reader.load(rootPath: fixture.root.path)
        #expect(content.markdown == fixture.markdown)
        #expect(!content.isPartial)
        #expect(Set(content.files.map(\.path)) == ["SKILL.md", "references", "references/guide.md"])
        #expect(try await reader.preview(rootPath: fixture.root.path, relativePath: "references/guide.md") == .text("说明"))
        try fixture.write("references/guide.md", text: "外部修改")
        #expect(try await reader.preview(rootPath: fixture.root.path, relativePath: "references/guide.md") == .text("外部修改"))
    }

    @Test("空文件、二进制与超限文件分别表达")
    func previewTypes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("empty.txt", text: "")
        try Data([0, 1, 2]).write(to: fixture.root.appendingPathComponent("binary"))
        try Data(repeating: 65, count: 17).write(to: fixture.root.appendingPathComponent("large"))
        let reader = try Fixture.reader(maximumBytes: 16)
        #expect(try await reader.preview(rootPath: fixture.root.path, relativePath: "empty.txt") == .text(""))
        #expect(try await reader.preview(rootPath: fixture.root.path, relativePath: "binary") == .binary)
        #expect(try await reader.preview(rootPath: fixture.root.path, relativePath: "large") == .tooLarge)
    }

    @Test("附件链接只显示证据，不读取外部目标")
    func blocksAttachments() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = fixture.base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("linked"), withDestinationURL: outside
        )
        let reader = try Fixture.reader()
        let snapshot = try await reader.load(rootPath: fixture.root.path)
        #expect(snapshot.files.contains { $0.path == "linked" && $0.kind == .symbolicLink })
        #expect(!snapshot.files.contains { $0.path.contains("secret") })
        await #expect(throws: SkillContentReadError.self) {
            try await reader.preview(rootPath: fixture.root.path, relativePath: "linked/secret.txt")
        }
    }

    @Test("已发现的物理根被替换成链接时要求重新扫描")
    func rejectsReplacedRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let saved = fixture.base.appendingPathComponent("saved")
        try FileManager.default.moveItem(at: fixture.root, to: saved)
        try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: saved)
        await #expect(throws: SkillContentReadError.self) {
            try await Fixture.reader().load(rootPath: fixture.root.path)
        }
    }

    @Test("条目和深度预算返回 partial，manifest 大小预算阻断正文")
    func reportsBudgets() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("a/b/file.md", text: "deep")
        let entries = try await Fixture.reader(maximumEntries: 2).load(rootPath: fixture.root.path)
        #expect(entries.files.count <= 2 && entries.isPartial)
        let depth = try await Fixture.reader(maximumDepth: 1).load(rootPath: fixture.root.path)
        #expect(depth.isPartial)
        #expect(!depth.files.contains { $0.path == "a/b/file.md" })
        await #expect(throws: SkillContentReadError.self) {
            try await Fixture.reader(maximumBytes: 4).load(rootPath: fixture.root.path)
        }
    }

    @Test("路径穿越与绝对附件路径被拒绝", arguments: ["../outside", "/etc/passwd", "a/../SKILL.md", "a//b"])
    func rejectsInvalidPath(_ path: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        await #expect(throws: SkillContentReadError.self) {
            try await Fixture.reader().preview(rootPath: fixture.root.path, relativePath: path)
        }
    }

    @Test("缺失与无效编码的 manifest 不能冒充空正文")
    func rejectsInvalidManifest() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data([0xFF, 0xFE]).write(to: fixture.root.appendingPathComponent("SKILL.md"))
        await #expect(throws: SkillContentReadError.self) {
            try await Fixture.reader().load(rootPath: fixture.root.path)
        }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("SKILL.md"))
        await #expect(throws: (any Error).self) {
            try await Fixture.reader().load(rootPath: fixture.root.path)
        }
    }

    @Test("取消请求优先于文件系统访问")
    func cancellation() async throws {
        let reader = try Fixture.reader()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reader.load(rootPath: "/does-not-exist")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("Markdown 只放行有主机的 HTTP 链接", arguments: [
        "https://github.com", "http://example.com", "file:///etc/passwd", "javascript:alert(1)",
        "mailto:a@example.com", "starcat://run", "relative.md", "https:relative"
    ])
    func linkPolicy(_ value: String) throws {
        let url = try #require(URL(string: value))
        #expect(SkillPreviewLinkPolicy.allows(url) == ["https://github.com", "http://example.com"].contains(value))
    }

    /// 显式渠道与物理临时根使测试不依赖宿主 App 的渠道或用户配置。
    private struct Fixture {
        let base: URL
        let root: URL
        let markdown = "---\nname: sample\ndescription: A sample\n---\n# Sample\n"

        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
            root = base.appendingPathComponent("content")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(markdown.utf8).write(to: root.appendingPathComponent("SKILL.md"))
        }

        func write(_ path: String, text: String) throws {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }

        func remove() { try? FileManager.default.removeItem(at: base) }

        static func reader(
            maximumBytes: Int = 1_048_576, maximumEntries: Int = 2_000, maximumDepth: Int = 6
        ) throws -> SkillContentReader {
            try SkillContentReader(
                distributionGate: DistributionGate(channel: .direct),
                maximumBytes: maximumBytes, maximumEntries: maximumEntries, maximumDepth: maximumDepth
            )
        }
    }
}
