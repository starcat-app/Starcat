//
//  CloneMenu.swift
//  Starcat
//
//  顶部 toolbar 「复制 clone URL」下拉菜单。
//
//  原归属：`RepoListView.cloneMenu(repo:)` + `httpsCloneURL` / `gitCloneURL` 私有
//  helper（仅 Manage 路径，闭包内直接读 `viewModel.selectedRepo`）。W12 toolbar
//  专项 PR-1 抽出，clone URL 兜底拼接逻辑下沉到 `ToolbarRepoSelection` 工厂，本
//  组件纯 UI 渲染 + 写剪贴板 + 回调通知调用方弹 toast。
//
//  关键约束：
//  - 复制成功 toast 由调用方在外层挂 `.toast(message:)` 渲染：本组件不持有 toast
//    状态，避免每个 toolbar 控件都管一份 @State；
//  - https / git URL 在 `ToolbarRepoSelection` 构造时就已经准备好（Manage 走本地
//    `cloneUrl` / `sshUrl`，trending / weekly 走 owner/name 兜底），渲染层零计算。
//  - 菜单只展示协议名称，不展示完整 URL。长 URL 会不必要地撑宽菜单，
//    用户的真实目标是点击后复制，复制结果仍由 toast 确认。
//

import SwiftUI
import AppKit

/// 顶部 toolbar 「复制 clone URL」菜单。
///
/// 复制成功通过 `onCopied(toastKey)` 回调通知调用方，由调用方决定如何提示用户。
struct CloneMenu: View {

    let selection: ToolbarRepoSelection
    let onCopied: (String) -> Void

    var body: some View {
        Menu {
            Button {
                copy(selection.cloneHTTPS, toastKey: "clone.copiedHttps")
            } label: {
                Label("clone.https", systemImage: "globe")
            }

            Divider()

            Button {
                copy(selection.cloneSSH, toastKey: "clone.copiedGit")
            } label: {
                Label("clone.git", systemImage: "terminal")
            }
        } label: {
            ToolbarIcon("doc.on.clipboard")
                .accessibilityLabel("clone.hint")
        }
        .help("clone.hint")
    }

    private func copy(_ string: String, toastKey: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        onCopied(toastKey)
    }
}
