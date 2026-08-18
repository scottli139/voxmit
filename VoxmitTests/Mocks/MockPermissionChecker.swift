import Foundation
@testable import Voxmit

/// PermissionChecking 的测试替身：状态全部内存可控，绝不触碰真实 TCC。
/// 仅单测使用（@unchecked：测试内按 await 串行访问，无并发竞争）。
final class MockPermissionChecker: PermissionChecking, @unchecked Sendable {
    var microphoneStatus: MicrophonePermissionStatus = .authorized
    var listenEventGranted = true
    var accessibilityGranted = true
    var requestMicrophoneAccessResult = true

    private(set) var requestMicrophoneAccessCallCount = 0
    private(set) var openedSettingsURLs: [URL] = []

    func microphoneAuthorizationStatus() -> MicrophonePermissionStatus { microphoneStatus }

    func preflightListenEventAccess() -> Bool { listenEventGranted }

    func isProcessTrusted() -> Bool { accessibilityGranted }

    func requestMicrophoneAccess() async -> Bool {
        requestMicrophoneAccessCallCount += 1
        if requestMicrophoneAccessResult {
            microphoneStatus = .authorized // 模拟用户在系统弹窗点「允许」
        }
        return requestMicrophoneAccessResult
    }

    @MainActor
    func openSystemSettingsPane(_ url: URL) -> Bool {
        openedSettingsURLs.append(url)
        return true
    }
}
