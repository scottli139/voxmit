import Foundation
import Testing
@testable import Voxmit

/// 权限快照的枚举组合与降级决策矩阵（需求文档 §4.4）
struct PermissionSnapshotTests {

    @Test func snapshot_allGranted_allThreeGranted_true() {
        let snapshot = PermissionSnapshot(
            microphone: .authorized, listenEventGranted: true, accessibilityGranted: true
        )
        #expect(snapshot.allGranted)
        #expect(snapshot.requiredGranted)
        #expect(snapshot.canRecord)
        #expect(snapshot.canUseGlobalHotkey)
        #expect(snapshot.injectionCapability == .full)
        #expect(snapshot.missingPermissions.isEmpty)
    }

    @Test(arguments: [MicrophonePermissionStatus.notDetermined, .denied, .restricted])
    func snapshot_microphoneNotAuthorized_cannotRecord(status: MicrophonePermissionStatus) {
        let snapshot = PermissionSnapshot(
            microphone: status, listenEventGranted: true, accessibilityGranted: true
        )
        #expect(!snapshot.canRecord)
        #expect(!snapshot.requiredGranted)
        #expect(snapshot.missingPermissions == [.microphone])
    }

    @Test func snapshot_listenEventMissing_hotkeyUnavailableAndRequiredIncomplete() {
        // 无输入监控 → 全局热键不可用（降级为菜单栏点击录音），且必需权限不齐
        let snapshot = PermissionSnapshot(
            microphone: .authorized, listenEventGranted: false, accessibilityGranted: true
        )
        #expect(!snapshot.canUseGlobalHotkey)
        #expect(!snapshot.requiredGranted)
        #expect(!snapshot.allGranted)
        #expect(snapshot.injectionCapability == .full)
        #expect(snapshot.missingPermissions == [.listenEvent])
    }

    @Test func snapshot_accessibilityMissing_injectionDegradesToClipboardOnly() {
        // 无辅助功能 → 注入降级仅剪贴板；辅助功能非必需，requiredGranted 不受影响
        let snapshot = PermissionSnapshot(
            microphone: .authorized, listenEventGranted: true, accessibilityGranted: false
        )
        #expect(snapshot.injectionCapability == .clipboardOnly)
        #expect(snapshot.requiredGranted)
        #expect(!snapshot.allGranted)
        #expect(snapshot.missingPermissions == [.accessibility])
    }

    @Test func snapshot_multipleMissing_missingPermissionsInGuideOrder() {
        // 缺失列表按引导顺序排列：麦克风 → 输入监控 → 辅助功能（§4.4）
        let snapshot = PermissionSnapshot(
            microphone: .denied, listenEventGranted: false, accessibilityGranted: false
        )
        #expect(snapshot.missingPermissions == [.microphone, .listenEvent, .accessibility])
    }

    @Test func snapshot_unknown_treatedAsNothingGranted() {
        #expect(PermissionSnapshot.unknown.missingPermissions == PermissionKind.allCases)
        #expect(PermissionSnapshot.unknown.injectionCapability == .clipboardOnly)
    }
}

/// PermissionManager 行为（mock PermissionChecking，不触碰真实系统权限）
struct PermissionManagerTests {

    @Test @MainActor func refresh_mockStates_snapshotReflectsChecker() {
        let checker = MockPermissionChecker()
        checker.microphoneStatus = .denied
        checker.listenEventGranted = false
        checker.accessibilityGranted = true

        let manager = PermissionManager(checker: checker)

        #expect(manager.snapshot.microphone == .denied)
        #expect(!manager.snapshot.canUseGlobalHotkey)
        #expect(manager.snapshot.injectionCapability == .full)
    }

    @Test @MainActor func refresh_stateChangedAfterInit_pickedUpOnRefresh() {
        let checker = MockPermissionChecker()
        checker.listenEventGranted = false
        let manager = PermissionManager(checker: checker)
        #expect(!manager.snapshot.canUseGlobalHotkey)

        checker.listenEventGranted = true
        manager.refresh()

        #expect(manager.snapshot.canUseGlobalHotkey)
    }

    @Test @MainActor func requestMicrophoneAccess_granted_snapshotBecomesAuthorized() async {
        let checker = MockPermissionChecker()
        checker.microphoneStatus = .notDetermined
        checker.requestMicrophoneAccessResult = true
        let manager = PermissionManager(checker: checker)

        let granted = await manager.requestMicrophoneAccess()

        #expect(granted)
        #expect(checker.requestMicrophoneAccessCallCount == 1)
        #expect(manager.snapshot.microphone == .authorized)
    }

    @Test @MainActor func requestMicrophoneAccess_denied_snapshotRemainsUnauthorized() async {
        let checker = MockPermissionChecker()
        checker.microphoneStatus = .notDetermined
        checker.requestMicrophoneAccessResult = false
        let manager = PermissionManager(checker: checker)

        let granted = await manager.requestMicrophoneAccess()

        #expect(!granted)
        #expect(manager.snapshot.microphone != .authorized)
    }

    @Test @MainActor func openSystemSettings_eachKind_forwardsExpectedDeepLink() {
        let checker = MockPermissionChecker()
        let manager = PermissionManager(checker: checker)

        for kind in PermissionKind.allCases {
            manager.openSystemSettings(for: kind)
        }

        // 深链常量在 macOS 26 实测有效（见 docs/implementation-notes.md），此断言锁定防回归
        #expect(checker.openedSettingsURLs.map(\.absoluteString) == [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ])
    }

    @Test func shouldPresentOnboarding_matrix_matchesExpectation() {
        let allGranted = PermissionSnapshot(
            microphone: .authorized, listenEventGranted: true, accessibilityGranted: true
        )
        let missing = PermissionSnapshot(
            microphone: .denied, listenEventGranted: false, accessibilityGranted: false
        )

        // 未完成引导且权限未集齐 → 展示；已完成或权限已集齐 → 不展示（§4.4）
        #expect(PermissionManager.shouldPresentOnboarding(hasCompletedOnboarding: false, snapshot: missing))
        #expect(!PermissionManager.shouldPresentOnboarding(hasCompletedOnboarding: true, snapshot: missing))
        #expect(!PermissionManager.shouldPresentOnboarding(hasCompletedOnboarding: false, snapshot: allGranted))
        #expect(!PermissionManager.shouldPresentOnboarding(hasCompletedOnboarding: true, snapshot: allGranted))
    }
}

/// VoicePipeline 的权限降级标记（数据流：PermissionManager → Pipeline）
struct VoicePipelinePermissionTests {

    @Test @MainActor func pipeline_applyPermissionSnapshot_drivesDegradationFlags() {
        let pipeline = VoicePipeline()
        // .unknown 视为全部未授权：热键不可用、注入仅剪贴板
        #expect(!pipeline.canUseGlobalHotkey)
        #expect(pipeline.injectionCapability == .clipboardOnly)

        pipeline.applyPermissionSnapshot(PermissionSnapshot(
            microphone: .authorized, listenEventGranted: true, accessibilityGranted: false
        ))
        #expect(pipeline.canUseGlobalHotkey)
        #expect(pipeline.injectionCapability == .clipboardOnly)

        pipeline.applyPermissionSnapshot(PermissionSnapshot(
            microphone: .authorized, listenEventGranted: true, accessibilityGranted: true
        ))
        #expect(pipeline.injectionCapability == .full)
    }
}

/// 引导完成标记的默认值注册
struct OnboardingSettingsTests {

    @Test func registerDefaults_onboardingCompleted_defaultsFalse() throws {
        let suiteName = "com.voxmit.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SettingsKeys.registerDefaults(in: defaults)

        #expect(defaults.bool(forKey: SettingsKeys.appOnboardingCompleted) == false)
    }
}
