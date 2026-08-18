import AppKit
import ApplicationServices
import AVFoundation
import Combine
import CoreGraphics

// 权限检测与引导（FR-G5，需求文档 §4.4 权限矩阵）。
// 系统 API 全部收敛在 PermissionChecking 协议背后，PermissionManager 依赖协议，
// 单测以 mock 注入，禁止在测试中触发真实 TCC 弹窗（见 docs/TESTING.md）。

/// 权限种类（需求文档 §4.4 权限矩阵）
///
/// CaseIterable 的顺序即首次启动引导顺序：麦克风 → 输入监控 → 辅助功能。
enum PermissionKind: String, Sendable, CaseIterable {
    case microphone
    case listenEvent
    case accessibility

    var displayName: String {
        switch self {
        case .microphone: return "麦克风"
        case .listenEvent: return "输入监控"
        case .accessibility: return "辅助功能"
        }
    }

    /// 该权限解锁的功能（§4.4「解锁功能」列）
    var purposeText: String {
        switch self {
        case .microphone:
            return "录音。语音输入的前提。"
        case .listenEvent:
            return "全局热键（按住右 Option 说话）。"
        case .accessibility:
            return "模拟按键注入与读取当前 App 上下文。"
        }
    }

    /// 缺失时的降级行为（§4.4「缺失时降级」列）
    var missingImpactText: String {
        switch self {
        case .microphone:
            return "无法录音，核心功能不可用。"
        case .listenEvent:
            return "热键失效，可改用菜单栏点击开始/停止录音。"
        case .accessibility:
            return "注入降级为「仅剪贴板」，需手动 Cmd+V 粘贴，且无上下文感知。"
        }
    }

    /// 必需权限 = 麦克风 + 输入监控；辅助功能可跳过、降级运行（§4.4 引导流程）
    var isRequired: Bool {
        self != .accessibility
    }

    /// 「打开系统设置」深链；macOS 26 实测有效（见 docs/implementation-notes.md）
    var systemSettingsURL: URL? {
        switch self {
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .listenEvent:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }
}

/// 麦克风授权状态（对应 AVAuthorizationStatus 四态）
enum MicrophonePermissionStatus: Sendable, Equatable {
    case notDetermined
    case restricted
    case denied
    case authorized

    var isGranted: Bool { self == .authorized }
}

/// 注入能力档位（需求文档 §4.4 降级矩阵）；Phase 8 注入按此选档
enum InjectionCapability: Sendable, Equatable {
    case full           // 剪贴板 + 模拟 Cmd+V（需辅助功能权限）
    case clipboardOnly  // 降级：仅剪贴板 + 提示手动粘贴
}

/// 三权限状态快照（需求文档 §4.4）；降级决策全部收敛在此，纯值类型可单测
struct PermissionSnapshot: Sendable, Equatable {
    var microphone: MicrophonePermissionStatus
    var listenEventGranted: Bool
    var accessibilityGranted: Bool

    /// 尚未查询时的占位值（全部按未授权处理，偏保守）
    static let unknown = PermissionSnapshot(
        microphone: .notDetermined,
        listenEventGranted: false,
        accessibilityGranted: false
    )

    func isGranted(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .microphone: return microphone.isGranted
        case .listenEvent: return listenEventGranted
        case .accessibility: return accessibilityGranted
        }
    }

    // MARK: 降级决策（§4.4 矩阵）

    /// 麦克风已授权才可录音（硬阻塞）
    var canRecord: Bool { microphone.isGranted }

    /// 输入监控已授权才可用全局热键；否则降级为菜单栏点击开始/停止录音
    var canUseGlobalHotkey: Bool { listenEventGranted }

    /// 无辅助功能权限时注入降级为仅剪贴板
    var injectionCapability: InjectionCapability {
        accessibilityGranted ? .full : .clipboardOnly
    }

    /// 必需权限（麦克风 + 输入监控）是否齐备
    var requiredGranted: Bool { canRecord && canUseGlobalHotkey }

    /// 三项权限是否全部齐备
    var allGranted: Bool { requiredGranted && accessibilityGranted }

    /// 未授权项，按引导顺序排列（麦克风 → 输入监控 → 辅助功能）
    var missingPermissions: [PermissionKind] {
        PermissionKind.allCases.filter { !isGranted($0) }
    }
}

/// 系统权限 API 隔离层（单测以 mock 注入，见 VoxmitTests/Mocks）
protocol PermissionChecking: Sendable {
    func microphoneAuthorizationStatus() -> MicrophonePermissionStatus
    func preflightListenEventAccess() -> Bool
    func isProcessTrusted() -> Bool
    /// 请求麦克风授权；仅在未决定状态时触发系统弹窗
    func requestMicrophoneAccess() async -> Bool
    /// 打开系统设置对应面板
    @MainActor func openSystemSettingsPane(_ url: URL) -> Bool
}

/// 真实系统实现（需求文档 §4.4「检测 API」列）
struct SystemPermissionChecker: PermissionChecking {
    func microphoneAuthorizationStatus() -> MicrophonePermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .denied
        }
    }

    func preflightListenEventAccess() -> Bool {
        CGPreflightListenEventAccess()
    }

    func isProcessTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    @MainActor
    func openSystemSettingsPane(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

/// 权限管理器（FR-G5）：状态查询、麦克风授权请求、系统设置跳转、首启引导判定
@MainActor
final class PermissionManager: ObservableObject {
    /// 当前权限快照；refresh() 时重新查询
    @Published private(set) var snapshot: PermissionSnapshot

    private let checker: any PermissionChecking

    init(checker: any PermissionChecking = SystemPermissionChecker()) {
        self.checker = checker
        self.snapshot = .unknown
        refresh()
    }

    /// 重新查询三项权限状态（检测 API 均不触发系统弹窗）
    func refresh() {
        snapshot = PermissionSnapshot(
            microphone: checker.microphoneAuthorizationStatus(),
            listenEventGranted: checker.preflightListenEventAccess(),
            accessibilityGranted: checker.isProcessTrusted()
        )
    }

    /// 请求麦克风授权（仅 notDetermined 时系统弹窗），完成后刷新快照
    @discardableResult
    func requestMicrophoneAccess() async -> Bool {
        let granted = await checker.requestMicrophoneAccess()
        refresh()
        return granted
    }

    /// 跳转系统设置对应面板
    func openSystemSettings(for kind: PermissionKind) {
        guard let url = kind.systemSettingsURL else { return }
        checker.openSystemSettingsPane(url)
    }

    /// 首次启动引导判定：未完成引导且权限未集齐时展示（§4.4）
    /// 纯函数，不访问实例状态，故 nonisolated 便于任意上下文调用与单测
    nonisolated static func shouldPresentOnboarding(
        hasCompletedOnboarding: Bool,
        snapshot: PermissionSnapshot
    ) -> Bool {
        !hasCompletedOnboarding && !snapshot.allGranted
    }
}
