//
//  DeepSeekHarnessRuntime.swift
//  Starcat
//
//  固定的 SDK 版本、入口与无本地工具补丁，供安装器和 Agent 共用。
//

/// Starcat 已验证的 DeepSeek Harness Runtime 契约。
///
/// Runtime 仍由用户通过外部路径安装；默认 Provider/Model 只保留给旧配置和显式
/// integration smoke。产品 UI 的真实目录来自 Starcat 已验证 AI Provider。
enum DeepSeekHarnessRuntime {
    static let packageVersion = "0.2.1rc2"
    static let executableName = "deepseek-harness-sdk-runtime-macos-arm64"
    static let defaultProvider = "deepseek-official"
    static let supportedModels = ["deepseek-v4-flash", "deepseek-v4-pro"]
    static let defaultModel = supportedModels[0]

    /// sdk-minimal 仍默认带本地 Shell。Starcat 仅授权自己的 MCP 工具，因此显式禁用
    /// 原生工具及其进程服务；每轮使用全新 DSH_HOME，避免读到用户的 profile 覆盖。
    /// 该 patch 与 resources/deepseek-harness/starcat.cordis.yml 保持一致。
    static let configurationPatch = """
    # Starcat Direct: sdk-minimal 的无本地工具补丁
    - id: llm-deepseek
      disabled: true
    - id: subprocess
      disabled: true
    - id: pty
      disabled: true
    - id: terminal-bash
      disabled: true
    - id: terminal-pwsh
      disabled: true
    - id: persistent-bash
      disabled: true
    - id: persistent-pwsh
      disabled: true
    - id: tool-fs
      disabled: true
    - id: tool-working-directory
      disabled: true
    - id: system-prompt
      config:
        includeHarnessIdentity: false
        includeRuntimeContext: false
        personaPrefix: You are a helpful assistant using only the tools supplied by Starcat.
    """
}
