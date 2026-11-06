//
//  DailyRadarCoverComposition.swift
//  Starcat
//
//  本地封面的确定性构图参数。身份与几何随机流不依赖视图尺寸或系统 Hasher，
//  让同篇报告在缩略图、主推卡和阅读页保持同一风格、配色与主要形体。
//

import Foundation

/// 六种空间组织规则；分类只增加偏好权重，不能把某分类锁死成一种封面。
enum DailyRadarCoverStyle: CaseIterable, Sendable {
    case terrain, network, orbital, architecture, strata, interference
}

/// 尺寸无关的封面身份；渲染时只按可见尺寸裁减次级细节。
struct DailyRadarCoverComposition: Equatable, Sendable {
    let style: DailyRadarCoverStyle
    let geometrySeed: UInt64
    let textureSeed: UInt64
    let hue: Double
    let accentHue: Double
    let backgroundHue: Double
    let phase: Double
    let tilt: Double

    /// 分开派生布局、几何和纹理流，修改纹理预算不会使主图重新随机。
    init(category: String?, seed: String) {
        var identity = SeededGenerator(seed: Self.stableHash("\(category ?? "")|\(seed)"))
        let preferred: DailyRadarCoverStyle
        let baseHue: Double
        switch category {
        case "ai-cli": preferred = .strata; baseHue = 0.52
        case "ai-agents": preferred = .network; baseHue = 0.30
        case "ai-infra": preferred = .architecture; baseHue = 0.67
        case "ai-web": preferred = .orbital; baseHue = 0.58
        case "ai-trending": preferred = .terrain; baseHue = 0.93
        case "ai-hn": preferred = .network; baseHue = 0.07
        case "ai-ph": preferred = .strata; baseHue = 0.03
        case "ai-arxiv": preferred = .interference; baseHue = 0.99
        case "ai-hf": preferred = .terrain; baseHue = 0.13
        case "ai-community": preferred = .network; baseHue = 0.40
        case "ai-weekly": preferred = .orbital; baseHue = 0.78
        case "ai-weekly-events": preferred = .network; baseHue = 0.46
        case "ai-monthly": preferred = .interference; baseHue = 0.62
        default: preferred = .terrain; baseHue = 0.58
        }
        let pool = DailyRadarCoverStyle.allCases + [preferred, preferred]
        style = pool[identity.int(pool.count)]
        geometrySeed = identity.next()
        textureSeed = identity.next()
        hue = Self.wrapped(baseHue + identity.range(-0.16, 0.16))
        // 邻近、三分与互补色均有机会出现，避免所有日报只有同色线条。
        let harmonies = [0.10, 0.30, 0.48, 0.64]
        accentHue = Self.wrapped(hue + harmonies[identity.int(harmonies.count)])
        backgroundHue = Self.wrapped(hue + identity.range(-0.08, 0.08))
        phase = identity.range(0, 2 * .pi)
        tilt = identity.range(-0.28, 0.28)
    }

    /// 三档有界采样；用短边限制细节，超宽但很矮的缩略图不会触发大图预算。
    static func detailLevel(for size: CGSize) -> Int {
        let edge = min(size.width, size.height)
        if edge < 110 { return 0 }
        if edge < 230 { return 1 }
        return 2
    }

    /// 安全区来自布局而非随机数；钳制后仍保留至少六成宽度绘制主体。
    static func safeLeading(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(max(value, 0), 0.4) : 0
    }

    /// 不使用进程间随机化的 Hasher，中文或其它 Unicode 身份也按标量稳定重放。
    private static func stableHash(_ value: String) -> UInt64 {
        value.unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) }
    }

    private static func wrapped(_ value: Double) -> Double {
        value - floor(value)
    }
}

/// splitmix64 的有界随机流。所有无符号运算显式允许溢出，避免种子触发 SIGTRAP。
struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func double() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func range(_ lower: Double, _ upper: Double) -> Double {
        lower + double() * (upper - lower)
    }

    mutating func int(_ count: Int) -> Int {
        Int(next() % UInt64(max(count, 1)))
    }
}
