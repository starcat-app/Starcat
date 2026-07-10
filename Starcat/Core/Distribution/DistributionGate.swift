//
//  DistributionGate.swift
//  Starcat
//
//  分发渠道能力门控。
//

import Foundation

/// 受分发渠道限制的功能。
///
/// 这里表达的是 App Store / Direct 构建边界，不表达 Pro 订阅权益。需要同时受
/// 订阅和渠道限制的能力，应先通过 `DistributionGate` 判断构建渠道，再通过
/// `EntitlementGate` 判断用户权益，避免把沙盒限制误写成付费规则。
enum ChannelFeature: String, CaseIterable, Sendable {
    /// Direct 版 Sparkle 自动更新。
    case automaticUpdates
    /// Direct 版官网支付与授权码激活。
    case directLicense
    /// Direct 版本机自动化能力，例如后续调用外部命令或非沙盒文件操作。
    case localAutomation
    /// Direct 版外部工具桥接，例如后续需要访问沙盒外工具链或用户环境。
    case externalToolBridge
}

/// 分发渠道门控失败。
enum DistributionGateError: Error, Equatable, Sendable {
    case directOnly(feature: ChannelFeature, current: DistributionChannel)
}

/// 统一判断当前构建渠道是否允许使用某项能力。
///
/// 业务代码不要直接根据 bundle id、receipt、Sparkle 是否存在等条件猜测渠道；渠道只能来自
/// `DistributionChannel`。本类型把“哪些能力只能 Direct 使用”的规则集中起来，让 UI 隐藏、
/// service 执行层拦截和单测使用同一套判断。
struct DistributionGate: Sendable {
    let channel: DistributionChannel

    init(channel: DistributionChannel = .current) {
        self.channel = channel
    }

    /// 当前渠道是否允许使用指定能力。
    func isAvailable(_ feature: ChannelFeature) -> Bool {
        switch feature {
        case .automaticUpdates,
             .directLicense,
             .localAutomation,
             .externalToolBridge:
            return channel.isDirect
        }
    }

    /// 要求指定能力可用；执行真实系统能力前必须调用，而不能只依赖 UI 隐藏入口。
    func requireAvailable(_ feature: ChannelFeature) throws {
        guard isAvailable(feature) else {
            throw DistributionGateError.directOnly(feature: feature, current: channel)
        }
    }

    /// 语义化别名：用于调用方明确知道该能力只属于 Direct 构建的场景。
    func requireDirect(_ feature: ChannelFeature) throws {
        try requireAvailable(feature)
    }
}
