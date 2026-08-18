import AppKit
import SwiftUI

/// 权限自检页的窗口托管
///
/// 菜单栏 App（LSUIElement）无主窗口，权限自检页不走 SwiftUI Window Scene，
/// 由这里手动管理 NSWindow 生命周期：重复打开时前置复用，关闭后释放引用
/// （视图随之销毁，PermissionOnboardingView 的状态轮询自动停止）。
@MainActor
final class PermissionOnboardingWindowController: NSObject {
    private var window: NSWindow?
    private var closeObserver: (any NSObjectProtocol)?
    private let permissionManager: PermissionManager
    private let onFinish: () -> Void

    init(permissionManager: PermissionManager, onFinish: @escaping () -> Void) {
        self.permissionManager = permissionManager
        self.onFinish = onFinish
        super.init()
    }

    /// 展示权限自检页；已打开时前置复用
    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let view = PermissionOnboardingView(
            permissionManager: permissionManager,
            onFinish: { [weak self] in self?.finish() }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "权限设置"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.windowDidClose() }
        }

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func finish() {
        onFinish()
        window?.close()
    }

    private func windowDidClose() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        window = nil
    }
}
