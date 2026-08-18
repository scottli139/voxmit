import AppKit
import Combine

/// App 级协调器：持有 VoicePipeline 与 PermissionManager，
/// 负责首次启动权限引导判定（FR-G5）与权限快照向 Pipeline 的实时同步。
///
/// 通过 `@NSApplicationDelegateAdaptor` 挂到 SwiftUI App 生命周期（见 VoxmitApp）。
@MainActor
final class VoxmitAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let permissionManager = PermissionManager()
    /// 音频采集（Phase 3 实装）；注入 Pipeline 替换 Phase 2 的 NoOp 占位
    let audioCapture = AudioCapture(maxDuration: VoicePipeline.maximumRecordingDuration)
    /// lazy：依赖 audioCapture，且避免 @MainActor 类显式 override init 的隔离问题
    private(set) lazy var pipeline = VoicePipeline(audio: audioCapture)

    /// 权限自检引导窗口；完成（含「跳过，降级运行」）时写入 UserDefaults 标记
    private lazy var onboardingController = PermissionOnboardingWindowController(
        permissionManager: permissionManager,
        onFinish: {
            UserDefaults.standard.set(true, forKey: SettingsKeys.appOnboardingCompleted)
        }
    )

    /// 权限快照同步订阅（随 App 生命周期存活）
    private var permissionSync: AnyCancellable?

    /// 全局热键（FR-B1/FR-B5）；按输入监控权限自动启停，无权限时菜单降级入口可用
    private lazy var hotkeyManager = HotkeyManager(permissionManager: permissionManager)

    /// 录音 HUD（Phase 4）：非激活面板，不抢焦点；多 Space/全屏可见
    private lazy var hudController = RecordingHUDController(pipeline: pipeline, audioCapture: audioCapture)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单测以 App 为宿主运行（TEST_HOST）：不弹引导窗口、不做权限同步接线，
        // 保证测试不依赖真实权限状态（docs/TESTING.md）
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        // 权限快照实时同步给 Pipeline（降级决策数据源，需求文档 §4.4）
        permissionSync = permissionManager.$snapshot.sink { [pipeline] snapshot in
            Task { @MainActor in
                pipeline.applyPermissionSnapshot(snapshot)
            }
        }

        // 热键事件 → 状态机（§4.2.0：HotkeyManager 只上报原始事件，时序判定在 Pipeline）
        hotkeyManager.onHotkeyDown = { [pipeline] bypass in
            pipeline.handleHotkeyDown(bypassModifierActive: bypass)
        }
        hotkeyManager.onHotkeyUp = { [pipeline] in pipeline.handleHotkeyUp() }
        hotkeyManager.onEscape = { [pipeline] in pipeline.cancel() }
        _ = hotkeyManager // 触发 lazy 创建，开始按权限状态监听

        // 5 分钟录音上限（FR-A3）：AudioCapture 计时，到点走"松手"流程
        audioCapture.onMaxDurationReached = { [pipeline] in
            Task { @MainActor in pipeline.handleMaxRecordingDuration() }
        }

        // 录音 HUD：订阅状态机与电平，自动出现/隐藏
        _ = hudController

        // 首次启动且权限未集齐 → 自动展示权限自检页（§4.4：麦克风 → 输入监控 → 辅助功能）
        let completed = UserDefaults.standard.bool(forKey: SettingsKeys.appOnboardingCompleted)
        if PermissionManager.shouldPresentOnboarding(
            hasCompletedOnboarding: completed,
            snapshot: permissionManager.snapshot
        ) {
            showPermissionOnboarding()
        }
    }

    /// 菜单栏「权限自检…」入口
    func showPermissionOnboarding() {
        permissionManager.refresh()
        onboardingController.show()
    }
}
