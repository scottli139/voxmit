import AppKit
import ApplicationServices
import Foundation

/// bundleID → 分类适配表（需求文档 §4.2.5 P0；纯逻辑可单测）。
/// AI CLI（Kimi Code / Claude Code 等）无独立 bundleID，归入其宿主终端的分类。
enum AppCategoryMapper {
    /// 终端类（CLI 宿主）
    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",        // iTerm2
        "dev.warp.Warp-Stable",         // Warp
        "com.mitchellh.ghostty",        // Ghostty
        "net.kovidgoyal.kitty",         // kitty
        "com.vandyke.SecureCRT",        // SecureCRT
        "org.alacritty",                // Alacritty
    ]

    /// 编辑器 / IDE
    static let editorBundleIDs: Set<String> = [
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "dev.zed.Zed",                   // Zed
        "com.apple.dt.Xcode",
        "com.sublimetext.4",             // Sublime Text
        "com.sublimetext.3",
        "com.visualstudio.code.oss",     // VS Code OSS
    ]

    /// 浏览器
    static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "com.microsoft.edgemac",         // Edge
        "company.thebrowser.Browser",    // Arc
    ]

    static func category(for bundleID: String) -> AppCategory {
        if terminalBundleIDs.contains(bundleID) { return .terminal }
        if editorBundleIDs.contains(bundleID) { return .editor }
        if browserBundleIDs.contains(bundleID) { return .browser }
        // JetBrains 全家桶（IntelliJ IDEA / AppCode / CLion / GoLand 等）
        if bundleID.hasPrefix("com.jetbrains.") { return .editor }
        return .other
    }
}

/// 系统工作区/AX 交互隔离层（单测 mock；参考 PermissionChecking 模式）
protocol SystemWorkspace: Sendable {
    /// 前台 App（pid/bundleID/名称；NSWorkspace，不需要权限）
    func frontmostApp() -> (pid: pid_t, bundleID: String, name: String)?
    /// AX 焦点窗口标题（需辅助功能权限；无权限/无焦点窗口返回 nil）
    func focusedWindowTitle(pid: pid_t) -> String?
}

/// 真实系统实现：NSWorkspace.frontmostApplication + AXUIElement 焦点窗口标题
struct NSWorkspaceSystem: SystemWorkspace {
    func frontmostApp() -> (pid: pid_t, bundleID: String, name: String)? {
        // NSWorkspace 在 macOS 26 SDK 为 @MainActor 标注；调用方均为 @MainActor
        // （VoicePipeline 与单测），assumeIsolated 安全
        MainActor.assumeIsolated {
            guard let app = NSWorkspace.shared.frontmostApplication,
                  let bundleID = app.bundleIdentifier else { return nil }
            return (app.processIdentifier, bundleID, app.localizedName ?? bundleID)
        }
    }

    func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil } // 无 AX 权限 → 降级为仅 App 名（§4.2.5）
        let app = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef
        else { return nil }
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window as! AXUIElement, kAXTitleAttribute as CFString, &titleRef
        ) == .success else { return nil }
        return titleRef as? String
    }
}

/// 上下文快照实装（FR-E1 / FR-F5，需求文档 §4.2.5 / §3.4.3）：
/// keyDown 瞬间由 VoicePipeline 调用，产出注入目标快照。
/// 降级矩阵（§4.2.5）：无 AX 权限 → 仅 App 名；App 无焦点窗口 → 仅 bundleID/名称；
/// 前台取不到 → "无上下文"（pid 0 + 空标识，润色退化为仅句式整理）。
/// 日志区分两条无标题路径：无辅助功能权限 vs 已授权但取不到焦点窗口（排障必需）。
struct RealContextCollector: ContextCollecting {
    private let workspace: any SystemWorkspace
    /// AX 权限判定（区分两条无标题日志路径；默认真实检查，单测注入）
    private let axTrustedProvider: @Sendable () -> Bool

    init(
        workspace: any SystemWorkspace = NSWorkspaceSystem(),
        axTrustedProvider: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.workspace = workspace
        self.axTrustedProvider = axTrustedProvider
    }

    func snapshotTarget() -> TargetSnapshot {
        guard let app = workspace.frontmostApp() else {
            AppLog.notice(.context, "目标快照：前台 App 取不到，进入「无上下文」模式")
            return TargetSnapshot(
                pid: 0, bundleID: "", appName: "",
                windowTitle: nil, capturedAt: Date()
            )
        }
        let title = workspace.focusedWindowTitle(pid: app.pid)
        let category = AppCategoryMapper.category(for: app.bundleID)
        if let title {
            AppLog.debug(.context, "目标快照：\(app.name)（\(app.bundleID)）分类 \(category)，窗口「\(title)」")
        } else if axTrustedProvider() {
            AppLog.debug(.context, "目标快照：\(app.name)（\(app.bundleID)）分类 \(category)，已授权 AX 但取不到焦点窗口标题")
        } else {
            AppLog.debug(.context, "目标快照：\(app.name)（\(app.bundleID)）分类 \(category)，无辅助功能权限，仅记录 App 名")
        }
        return TargetSnapshot(
            pid: app.pid,
            bundleID: app.bundleID,
            appName: app.name,
            windowTitle: title,
            capturedAt: Date()
        )
    }
}
