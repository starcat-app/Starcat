// swift-tools-version: 5.9
import PackageDescription

// Vendored from Jakubantalik/Libraries.dev
// packages/thinking-orbs/ports/ios/ThinkingOrbsKit（来源见 VENDOR.md）。
//
// 原包的 Tests/ 依赖 monorepo 根目录 spec/orbs-golden.json（在 test 里用
// repoRoot 向上定位），未随包 vendor，故此处只保留 library target，删掉
// testTarget，避免指向不存在的 Tests 目录。
let package = Package(
    name: "ThinkingOrbsKit",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "ThinkingOrbsKit", targets: ["ThinkingOrbsKit"])
    ],
    targets: [
        .target(name: "ThinkingOrbsKit")
    ]
)
