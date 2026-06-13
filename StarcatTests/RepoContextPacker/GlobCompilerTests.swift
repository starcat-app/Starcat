//
//  GlobCompilerTests.swift
//  StarcatTests
//
//  验证 GlobCompiler glob→regex 转换的 5 类语法（§22.3 Q2 决议边界）：
//    - `*`（单目录内匹配，不跨 `/`）
//    - `**`（跨目录匹配）
//    - `?`（单字符，不跨 `/`）
//    - `{a,b,c}`（字符类）
//    - 元字符 `. ( ) + $ ^ | [ ] \` 自动转义
//

import Testing
@testable import Starcat

@Suite("GlobCompiler")
struct GlobCompilerTests {

    // MARK: - * 单目录内匹配

    @Test("* 命中单目录内任意字符")
    func starMatchesWithinDirectory() throws {
        let regex = try GlobCompiler.toRegex("*.ts")
        #expect(GlobCompiler.matches(regex, path: "index.ts"))
        #expect(GlobCompiler.matches(regex, path: "main.ts"))
    }

    @Test("* 不跨目录边界")
    func starDoesNotCrossDirectory() throws {
        let regex = try GlobCompiler.toRegex("*.ts")
        // `src/index.ts` 含 `/` —— `*` 不应该跨 `/` 匹配
        #expect(!GlobCompiler.matches(regex, path: "src/index.ts"))
    }

    // MARK: - ** 跨目录匹配

    @Test("** 跨目录")
    func doubleStarCrossesDirectory() throws {
        let regex = try GlobCompiler.toRegex("src/**/*.ts")
        #expect(GlobCompiler.matches(regex, path: "src/utils/helper.ts"))
        #expect(GlobCompiler.matches(regex, path: "src/index.ts"))
    }

    @Test("** 顶层 ignore pattern")
    func doubleStarTopLevel() throws {
        let regex = try GlobCompiler.toRegex("**/node_modules/**")
        #expect(GlobCompiler.matches(regex, path: "node_modules/react/index.js"))
        #expect(GlobCompiler.matches(regex, path: "frontend/node_modules/react/index.js"))
    }

    // MARK: - ? 单字符

    @Test("? 匹配单字符")
    func questionMarkMatchesSingleChar() throws {
        let regex = try GlobCompiler.toRegex("file?.ts")
        #expect(GlobCompiler.matches(regex, path: "file1.ts"))
        #expect(GlobCompiler.matches(regex, path: "fileA.ts"))
        // 两个字符不命中
        #expect(!GlobCompiler.matches(regex, path: "file12.ts"))
    }

    // MARK: - {a,b,c} 字符类

    @Test("{a,b,c} 多选")
    func braceExpansion() throws {
        let regex = try GlobCompiler.toRegex("src/*.{ts,tsx,js}")
        #expect(GlobCompiler.matches(regex, path: "src/index.ts"))
        #expect(GlobCompiler.matches(regex, path: "src/App.tsx"))
        #expect(GlobCompiler.matches(regex, path: "src/util.js"))
        #expect(!GlobCompiler.matches(regex, path: "src/style.css"))
    }

    @Test("没有匹配的 } → 抛错")
    func unmatchedBraceThrows() {
        #expect(throws: GlobCompileError.self) {
            _ = try GlobCompiler.toRegex("{abc")
        }
    }

    // MARK: - 元字符转义

    @Test("元字符 . 不应被当作 regex 通配")
    func dotIsEscaped() throws {
        let regex = try GlobCompiler.toRegex(".env")
        #expect(GlobCompiler.matches(regex, path: ".env"))
        // 如果 . 没转义，会匹配任意单字符如 `aenv`
        #expect(!GlobCompiler.matches(regex, path: "aenv"))
    }

    @Test("元字符 + 不应被当作 regex 量词")
    func plusIsEscaped() throws {
        let regex = try GlobCompiler.toRegex("c++.txt")
        #expect(GlobCompiler.matches(regex, path: "c++.txt"))
    }

    // MARK: - case-sensitive 决议（§22.3）

    @Test("case-sensitive：README.md 与 readme.md 不等价")
    func caseSensitive() throws {
        let regex = try GlobCompiler.toRegex("README.md")
        #expect(GlobCompiler.matches(regex, path: "README.md"))
        #expect(!GlobCompiler.matches(regex, path: "readme.md"))
    }

    // MARK: - 批量 API

    @Test("compileAll + matchesAny 联用")
    func compileAllAndMatchesAny() throws {
        let regexes = try GlobCompiler.compileAll([
            "**/node_modules/**",
            "**/*.log",
            "**/*.pyc",
        ])
        #expect(GlobCompiler.matchesAny(regexes, path: "node_modules/react/index.js"))
        #expect(GlobCompiler.matchesAny(regexes, path: "src/app.log"))
        #expect(!GlobCompiler.matchesAny(regexes, path: "src/index.ts"))
    }
}
