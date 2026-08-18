import SwiftUI

/// 权限自检页（FR-G5，需求文档 §4.4 / §4.6）
///
/// 三权限状态总览（按引导顺序：麦克风 → 输入监控 → 辅助功能）+ 逐项
/// 「打开系统设置」深链 + 窗口可见期间每秒轮询刷新（窗口关闭后自动停止）。
/// 首次启动由 VoxmitAppDelegate 自动弹出；菜单栏「权限自检…」可随时打开。
struct PermissionOnboardingView: View {
    @ObservedObject var permissionManager: PermissionManager
    /// 完成引导（含「跳过，降级运行」）：写 UserDefaults 标记并关闭窗口
    let onFinish: () -> Void

    /// 窗口可见期间每秒刷新权限状态；视图随窗口关闭销毁，订阅随之停止
    private let refreshTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            ForEach(PermissionKind.allCases, id: \.self) { kind in
                permissionRow(kind)
            }
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 480)
        .onReceive(refreshTimer) { _ in
            Task { @MainActor in permissionManager.refresh() }
        }
        .onAppear {
            permissionManager.refresh()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("权限设置")
                .font(.title2)
                .bold()
            Text("Voxmit 需要以下系统权限。请按顺序逐项开启：麦克风与输入监控为必需；辅助功能可跳过，缺失时降级运行。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionRow(_ kind: PermissionKind) -> some View {
        let granted = permissionManager.snapshot.isGranted(kind)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title3)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(kind.displayName)
                        .font(.headline)
                    Text(kind.isRequired ? "必需" : "可选")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(.secondary.opacity(0.5), lineWidth: 1)
                        }
                    Text(statusText(for: kind))
                        .font(.caption)
                        .foregroundStyle(granted ? .green : .orange)
                }
                Text(kind.purposeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !granted {
                    Text("未授权：\(kind.missingImpactText)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                if kind == .microphone, permissionManager.snapshot.microphone == .notDetermined {
                    Button("请求授权") {
                        Task { await permissionManager.requestMicrophoneAccess() }
                    }
                }
                Button("打开系统设置") {
                    permissionManager.openSystemSettings(for: kind)
                }
            }
        }
    }

    private func statusText(for kind: PermissionKind) -> String {
        switch kind {
        case .microphone:
            switch permissionManager.snapshot.microphone {
            case .authorized: return "已授权"
            case .notDetermined: return "未请求"
            case .denied, .restricted: return "已拒绝"
            }
        case .listenEvent, .accessibility:
            return permissionManager.snapshot.isGranted(kind) ? "已授权" : "未授权"
        }
    }

    @ViewBuilder
    private var footer: some View {
        let snapshot = permissionManager.snapshot
        HStack(spacing: 12) {
            if snapshot.allGranted {
                Label("所有权限已就绪。", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("完成") { onFinish() }
                    .keyboardShortcut(.defaultAction)
            } else if snapshot.requiredGranted {
                // 辅助功能非必需：可跳过并降级运行（§4.4）
                Text("辅助功能未授权：注入将降级为「仅剪贴板」，需手动 Cmd+V 粘贴。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("跳过，降级运行") { onFinish() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Text("请先授予必需权限（麦克风、输入监控）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("完成") {}
                    .disabled(true)
            }
        }
    }
}

#Preview {
    PermissionOnboardingView(permissionManager: PermissionManager(), onFinish: {})
}
