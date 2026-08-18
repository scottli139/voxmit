import AppKit
import SwiftUI

@main
struct VoxmitApp: App {
    @NSApplicationDelegateAdaptor(VoxmitAppDelegate.self) private var appDelegate

    init() {
        // 注册需求文档 §9.2 设置项默认值（register 仅在键缺失时生效，不覆盖用户已修改的值）
        SettingsKeys.registerDefaults()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(
                pipeline: appDelegate.pipeline,
                permissionManager: appDelegate.permissionManager,
                showPermissionOnboarding: appDelegate.showPermissionOnboarding
            )
        } label: {
            MenuBarIconView(pipeline: appDelegate.pipeline)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
        }
    }
}

/// 菜单栏图标，随 Pipeline 状态变化
private struct MenuBarIconView: View {
    @ObservedObject var pipeline: VoicePipeline

    var body: some View {
        Image(systemName: pipeline.menuBarIcon)
    }
}

/// 菜单栏菜单内容（含 FR-G5 权限自检入口与权限缺失提示）
private struct MenuBarContentView: View {
    @ObservedObject var pipeline: VoicePipeline
    @ObservedObject var permissionManager: PermissionManager
    let showPermissionOnboarding: () -> Void

    var body: some View {
        Text(pipeline.statusText)

        // 降级入口（需求文档 §4.4）：无输入监控权限时全局热键不可用，
        // 菜单栏点击开始/停止录音，与热键路径走同一个状态机
        if !permissionManager.snapshot.canUseGlobalHotkey {
            Button(pipeline.isRecording ? "停止录音（菜单栏入口）" : "开始录音（菜单栏入口）") {
                pipeline.handleMenuToggle()
            }
            .disabled(!permissionManager.snapshot.canRecord)
        }

        Divider()

        // 权限不全时给出提示（FR-G5）
        if !permissionManager.snapshot.allGranted {
            let missing = permissionManager.snapshot.missingPermissions
                .map(\.displayName)
                .joined(separator: "、")
            Text("⚠️ 权限未集齐：\(missing)")
        }
        Button("权限自检…") {
            showPermissionOnboarding()
        }

        SettingsLink {
            Text("设置…")
        }

        Divider()

        Button("退出 Voxmit") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
