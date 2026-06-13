//
//  DirectoryTreeBuilderTests.swift
//  StarcatTests
//
//  验证 DefaultDirectoryTreeBuilder 的缩进列表格式（§22.10 决议）：
//    - 2 空格缩进
//    - 目录后跟 `/`
//    - 按 path 字典序
//

import Testing
import Foundation
@testable import Starcat

@Suite("DirectoryTreeBuilder")
struct DirectoryTreeBuilderTests {

    private func makeFile(_ path: String) -> FilteredFile {
        FilteredFile(
            relativePath: path,
            absoluteURL: URL(fileURLWithPath: "/tmp/\(path)"),
            sizeBytes: 100
        )
    }

    @Test("单文件无嵌套")
    func singleFlatFile() {
        let builder = DefaultDirectoryTreeBuilder()
        let tree = builder.build([makeFile("README.md")])
        #expect(tree == "README.md")
    }

    @Test("两级嵌套")
    func twoLevelNested() {
        let builder = DefaultDirectoryTreeBuilder()
        let tree = builder.build([makeFile("src/index.ts")])
        // src/ + 2 空格缩进 index.ts
        let expected = """
        src/
          index.ts
        """
        #expect(tree == expected)
    }

    @Test("多文件同目录不重复输出目录头")
    func sharedDirectoryNotDuplicated() {
        let builder = DefaultDirectoryTreeBuilder()
        let tree = builder.build([
            makeFile("src/a.ts"),
            makeFile("src/b.ts"),
        ])
        let expected = """
        src/
          a.ts
          b.ts
        """
        #expect(tree == expected)
    }

    @Test("混合：顶级文件 + 嵌套文件按字典序")
    func mixedLayout() {
        let builder = DefaultDirectoryTreeBuilder()
        let tree = builder.build([
            makeFile("README.md"),
            makeFile("package.json"),
            makeFile("src/index.ts"),
        ])
        // 字典序：README.md（R）→ package.json（p，小写）→ src/index.ts
        // 注：ASCII 表里 R(82) < p(112) < s(115)
        let expected = """
        README.md
        package.json
        src/
          index.ts
        """
        #expect(tree == expected)
    }

    @Test("三级嵌套缩进正确")
    func threeLevelNested() {
        let builder = DefaultDirectoryTreeBuilder()
        let tree = builder.build([makeFile("src/utils/helper.ts")])
        let expected = """
        src/
          utils/
            helper.ts
        """
        #expect(tree == expected)
    }

    @Test("空输入 → 空字符串")
    func emptyInput() {
        let builder = DefaultDirectoryTreeBuilder()
        #expect(builder.build([]) == "")
    }
}
