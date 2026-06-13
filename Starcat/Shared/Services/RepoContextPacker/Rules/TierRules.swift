// MARK: - TierRules
//
// Packer pipeline 的**全部硬编码规则集**：默认 ignore 模式 / Tier 0 文件清单 / Tier 1 入口
// 文件 glob / 文本扩展名白名单 / 大小限制阈值 / 经验系数。
//
// 集中放一个文件的设计权衡（§22.3 Q2 决议）：
//   ✅ 编译时类型保证 + grep 友好 + 单文件 ~250 行可控
//   ❌ 不用 JSON / Markdown 数据源生成（不必要的运行时 / build script 负担）
//
// 数据来源：
//   1. defaultIgnorePatterns —— 照抄 repomix `core/config/defaultIgnore.js`（v1.14.1），85 条
//   2. tier0ExactNames / tier0GlobPatterns —— Starcat 自定义（基于 §5.2 经验列表）
//   3. tier1GlobPatterns —— Starcat 自定义（基于 §5.3 经验列表，含 Swift @main 入口）
//   4. textExtensions / textFilenames —— Starcat 自定义（§22.7 Q6 决议）
//   5. 大小限制阈值 —— §22.11 Q10 决议
//   6. token 经验系数 —— repomix 实测值 0.27（§22.8 Q7 决议）
//
// ⚠️ 版本管理约定：修改任何规则集 → bump `tierRulesVersion`（如 1.0 → 1.1），让产物
// metadata 能识别新旧版。bump 后必须同步设计文档 §22 决议表。

import Foundation

public enum TierRules {

    // MARK: - 版本号

    /// Tier 规则集版本。修改任何规则 → bump（如 1.0 → 1.1）。
    /// 嵌入 `context.xml` 的 `<repository tierRulesVersion="...">` 属性。
    public static let tierRulesVersion = "1.0"

    // MARK: - Pass 3 并发上限

    /// Pass 3 XmlOutputBuilder TaskGroup 并发读取的上限（§22.5 Q4 决议）。
    /// 取 8 是为了防止文件描述符耗尽 + macOS 沙箱 IO 调度过载；Tier 0/1 通常 < 20 个，cap 8 足够。
    public static let contentReadConcurrencyCap = 8

    // MARK: - 大小限制阈值（§22.11 Q10 决议）

    /// ZIP 文件自身上限（100MB）。Pass 0 解压**之前** check，超出抛 `zipTooLarge`。
    public static let zipMaxBytes = 100 * 1024 * 1024

    /// 解压后总大小上限（500MB）。Pass 0 解压**之后** check，是 ZIP bomb 兜底。
    public static let extractedMaxBytes = 500 * 1024 * 1024

    /// 单源码文件上限（5MB）。Pass 1 FileFilter check，超出强制降级 Tier 2 + skippedFiles。
    public static let singleFileMaxBytes = 5 * 1024 * 1024

    // MARK: - Token 经验系数（§22.8 Q7 决议）

    /// 字符数 → token 数的经验系数（GPT-4 tokenizer 实测 0.27，误差 ±10%）。
    public static let charToTokenRatio = 0.27

    /// Token estimator 版本字符串，写入 metadata。V2 切 tiktoken-swift 后会变成
    /// `tiktoken-cl100k` 之类。
    public static let tokenEstimatorVersion = "char-x-0.27"

    // MARK: - 默认 ignore 列表（85 条，照搬 repomix defaultIgnore.js v1.14.1）
    //
    // 维护指南：
    //   - 顺序与 repomix 上游一致（便于 diff 同步）
    //   - 修改前先核对上游：https://github.com/yamadashy/repomix/blob/main/src/config/defaultIgnore.ts
    //   - 任何修改都要 bump `tierRulesVersion`

    public static let defaultIgnorePatterns: [String] = [
        // VCS / 元数据
        "**/.git/**",
        "**/.svn/**",
        "**/.hg/**",
        "**/.bzr/**",
        "**/CVS/**",

        // 依赖 / 包管理产物
        "**/node_modules/**",
        "**/bower_components/**",
        "**/jspm_packages/**",
        "**/vendor/**",

        // 构建产物
        "**/dist/**",
        "**/build/**",
        "**/out/**",
        "**/target/**",
        "**/bin/**",
        "**/obj/**",
        "**/output/**",
        "**/Output/**",
        "**/Builds/**",

        // 缓存目录
        "**/.cache/**",
        "**/.npm/**",
        "**/.pnpm/**",
        "**/.yarn/**",
        "**/.next/**",
        "**/.nuxt/**",
        "**/.vite/**",
        "**/.turbo/**",
        "**/.parcel-cache/**",
        "**/.svelte-kit/**",
        "**/.angular/**",
        "**/.docusaurus/**",
        "**/.gatsby/**",
        "**/.expo/**",
        "**/.serverless/**",
        "**/.terraform/**",
        "**/.vagrant/**",

        // Python 工具链
        "**/__pycache__/**",
        "**/*.pyc",
        "**/*.pyo",
        "**/*.pyd",
        "**/.venv/**",
        "**/venv/**",
        "**/env/**",
        "**/.env/**",
        "**/.tox/**",
        "**/.pytest_cache/**",
        "**/.mypy_cache/**",
        "**/.ruff_cache/**",
        "**/.coverage",
        "**/.coverage.*",
        "**/htmlcov/**",
        "**/.python-version",
        "**/*.egg-info/**",

        // Rust
        "**/Cargo.lock",

        // Java / Gradle / Maven
        "**/*.class",
        "**/.gradle/**",
        "**/.mvn/**",
        "**/gradle/**",

        // .NET
        "**/bin/Debug/**",
        "**/bin/Release/**",
        "**/obj/Debug/**",
        "**/obj/Release/**",

        // iOS / Xcode
        "**/Pods/**",
        "**/Carthage/**",
        "**/DerivedData/**",
        "**/*.xcworkspace/**",
        "**/*.xcodeproj/**",
        "**/xcuserdata/**",
        "**/*.dSYM/**",

        // 编辑器 / IDE
        "**/.idea/**",
        "**/.vscode/**",
        "**/.vs/**",
        "**/.history/**",
        "**/.fleet/**",

        // OS 元数据
        "**/.DS_Store",
        "**/Thumbs.db",
        "**/desktop.ini",
        "**/.localized",
        "**/__MACOSX/**",

        // 日志 / 临时
        "**/*.log",
        "**/*.tmp",
        "**/*.temp",
        "**/*.swp",
        "**/*.swo",
        "**/*~",
        "**/.tmp/**",

        // Lock 文件（不算 binary 但对源码理解无帮助；package.json 已经在 Tier 0）
        "**/yarn.lock",
        "**/pnpm-lock.yaml",
        "**/package-lock.json",
        "**/composer.lock",
        "**/Gemfile.lock",
        "**/Pipfile.lock",
        "**/poetry.lock",
        "**/uv.lock",

        // 二进制 / 媒体（fast-path：即使白名单没列，扩展名 ignore 也能挡掉）
        "**/*.exe",
        "**/*.dll",
        "**/*.so",
        "**/*.dylib",
        "**/*.a",
        "**/*.lib",
        "**/*.o",
        "**/*.zip",
        "**/*.tar",
        "**/*.tar.gz",
        "**/*.tgz",
        "**/*.rar",
        "**/*.7z",
        "**/*.gz",
        "**/*.bz2",
        "**/*.pdf",
        "**/*.png",
        "**/*.jpg",
        "**/*.jpeg",
        "**/*.gif",
        "**/*.webp",
        "**/*.ico",
        "**/*.bmp",
        "**/*.tif",
        "**/*.tiff",
        "**/*.mp3",
        "**/*.mp4",
        "**/*.avi",
        "**/*.mov",
        "**/*.wmv",
        "**/*.mkv",
        "**/*.flac",
        "**/*.wav",
        "**/*.ogg",
        "**/*.webm",
        "**/*.woff",
        "**/*.woff2",
        "**/*.ttf",
        "**/*.otf",
        "**/*.eot",
    ]

    // MARK: - Tier 0：精确文件名匹配（无扩展名 / 大小写敏感）

    /// Tier 0 文件按精确名命中：README / LICENSE / CHANGELOG / 主流包管理元文件 / Dockerfile 等。
    /// 这些是「项目宪法级」文件，全文输出给 LLM。
    public static let tier0ExactNames: Set<String> = [
        // README / 文档
        "README", "README.md", "README.rst", "README.adoc", "README.txt", "README.markdown",
        "CHANGELOG", "CHANGELOG.md", "CHANGES", "CHANGES.md",
        "CONTRIBUTING", "CONTRIBUTING.md",
        "CODE_OF_CONDUCT", "CODE_OF_CONDUCT.md",

        // LICENSE / 法律
        "LICENSE", "LICENSE.md", "LICENSE.txt", "LICENCE", "LICENCE.md",
        "COPYING", "COPYING.md", "COPYING.LESSER",
        "NOTICE", "NOTICE.md",
        "AUTHORS", "AUTHORS.md", "CONTRIBUTORS", "CONTRIBUTORS.md",

        // 包管理 / 依赖元信息
        "package.json", "tsconfig.json", "jsconfig.json",
        "Cargo.toml", "Cargo.lock",  // Cargo.lock 在 ignore 里，但 Cargo.toml 全文
        "go.mod", "go.sum",
        "Pipfile", "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "uv.toml",
        "Gemfile", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
        "pom.xml",
        "composer.json",
        "mix.exs",
        "Package.swift", "Podfile", "Cartfile",
        "pubspec.yaml",
        "deno.json", "deno.jsonc",
        "bun.lockb",  // 二进制不读，但列出
        "Brewfile",

        // 容器 / 部署
        "Dockerfile", "Dockerfile.dev", "Dockerfile.prod",
        "docker-compose.yml", "docker-compose.yaml",
        "Procfile",
        "Makefile", "GNUmakefile", "Rakefile",
        "Justfile", "justfile",
        ".env.example", ".env.sample",
    ]

    // MARK: - Tier 0：glob 匹配（按文件后缀 / 路径前缀）

    /// Tier 0 文件按 glob 命中（如 `*.csproj` 是 C# 项目元数据）。
    public static let tier0GlobPatterns: [String] = [
        // 项目元数据
        "*.csproj",
        "*.fsproj",
        "*.vbproj",
        "*.gemspec",
        "*.podspec",
        "*.opam",
        "*.cabal",

        // CI 配置
        ".github/workflows/*.yml",
        ".github/workflows/*.yaml",
        ".gitlab-ci.yml",
        ".circleci/config.yml",
        ".travis.yml",
        "azure-pipelines.yml",
        "appveyor.yml",
        ".drone.yml",
        "Jenkinsfile",
        "bitbucket-pipelines.yml",
    ]

    // MARK: - Tier 1：入口文件 glob

    /// Tier 1 入口文件 glob 列表（明确的 main / index / @main 入口）。
    /// 命中后头 80 行 + 4000 字符双约束截断输出。
    public static let tier1GlobPatterns: [String] = [
        // JavaScript / TypeScript 生态
        "src/index.ts", "src/index.tsx", "src/index.js", "src/index.jsx", "src/index.mjs", "src/index.cjs",
        "src/main.ts", "src/main.tsx", "src/main.js", "src/main.jsx",
        "src/app.ts", "src/app.tsx", "src/app.js", "src/app.jsx",
        "index.ts", "index.tsx", "index.js", "index.jsx",
        "main.ts", "main.tsx", "main.js", "main.jsx",
        "app.ts", "app.tsx", "app.js", "app.jsx",

        // Python
        "src/main.py", "src/__main__.py",
        "main.py", "__main__.py", "app.py", "manage.py", "wsgi.py", "asgi.py",

        // Rust
        "src/main.rs", "src/lib.rs",

        // Go
        "main.go", "cmd/*/main.go",

        // Swift（@main 注解扫描另起，本 glob 覆盖典型路径）
        "Sources/*/main.swift",
        "*/App.swift",
        "*App.swift",

        // Java / Kotlin
        "src/main/java/**/Main.java",
        "src/main/java/**/Application.java",
        "src/main/kotlin/**/Main.kt",
        "src/main/kotlin/**/Application.kt",

        // C / C++
        "main.c", "main.cpp", "main.cc", "main.cxx",
        "src/main.c", "src/main.cpp", "src/main.cc",

        // C# / .NET
        "Program.cs",
        "src/Program.cs",

        // Ruby
        "bin/*", "lib/*.rb",

        // PHP
        "index.php", "public/index.php",

        // Dart
        "lib/main.dart", "bin/main.dart",
    ]

    // MARK: - 文本扩展名白名单（§22.7 Q6 决议）
    //
    // FileFilter 的 fast-path：扩展名在白名单 → 候选文本文件；不在 → 默认 ignore。
    // **大小写不敏感**比较时，先把扩展名小写化。

    public static let textExtensions: Set<String> = [
        // 源码：通用编程语言
        "swift", "kt", "kts", "java", "scala", "groovy",
        "py", "rb", "php", "lua", "perl", "pl",
        "js", "ts", "tsx", "jsx", "mjs", "cjs",
        "go", "rs",
        "c", "cpp", "cc", "cxx", "h", "hpp", "hxx", "m", "mm",
        "cs", "fs", "vb",
        "dart",
        "ex", "exs", "erl", "hrl",
        "clj", "cljs", "cljc",
        "hs", "lhs",
        "ml", "mli",
        "nim",
        "zig",
        "v",

        // 脚本
        "sh", "zsh", "fish", "bash", "ps1", "bat", "cmd", "ksh", "csh",

        // 标记 / 文档
        "md", "markdown", "mdx", "rst", "adoc", "asciidoc", "txt", "tex",

        // 配置 / 数据
        "json", "jsonc", "json5",
        "yaml", "yml",
        "toml",
        "xml", "plist",
        "html", "htm", "xhtml",
        "css", "scss", "sass", "less", "styl",
        "ini", "conf", "config", "cnf", "properties",
        "env",

        // Web 资源（text-based）
        "svg",

        // Database / Query
        "sql", "graphql", "gql",

        // 其它
        "proto", "thrift", "avsc",
        "tf", "tfvars",
        "lock",  // 注意 lock 文件大多在 ignore 列表
        "gitignore", "gitattributes", "editorconfig", "npmrc", "babelrc", "eslintrc", "prettierrc",
    ]

    // MARK: - 无扩展名文件白名单（§22.7 Q6 决议）

    public static let textFilenames: Set<String> = [
        "LICENSE", "COPYING", "NOTICE", "AUTHORS", "CONTRIBUTORS", "CHANGELOG",
        "README", "TODO", "VERSION", "MAINTAINERS",
        "Makefile", "GNUmakefile", "Rakefile", "Gemfile", "Procfile", "Brewfile",
        "Dockerfile", "Justfile", "Vagrantfile",
        ".dockerignore", ".gitignore", ".gitattributes", ".editorconfig",
        ".npmrc", ".babelrc", ".eslintrc", ".prettierrc", ".stylelintrc",
        ".browserslistrc", ".nvmrc", ".node-version", ".python-version",
        ".env.example", ".env.sample",
        "Jenkinsfile",
    ]
}
