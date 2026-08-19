import Foundation
import Testing
@testable import Voxmit

/// 系统工作区 mock（降级矩阵驱动）
private final class MockSystemWorkspace: SystemWorkspace, @unchecked Sendable {
    var frontmost: (pid: pid_t, bundleID: String, name: String)? = (4242, "com.apple.Terminal", "Terminal")
    var windowTitle: String? = "voxmit — zsh"

    func frontmostApp() -> (pid: pid_t, bundleID: String, name: String)? { frontmost }
    func focusedWindowTitle(pid: pid_t) -> String? { windowTitle }
}

/// 上下文快照降级矩阵（§4.2.5）
struct RealContextCollectorTests {

    @Test func snapshot_fullAccess_allFields() {
        let collector = RealContextCollector(workspace: MockSystemWorkspace())

        let snapshot = collector.snapshotTarget()

        #expect(snapshot.pid == 4242)
        #expect(snapshot.bundleID == "com.apple.Terminal")
        #expect(snapshot.appName == "Terminal")
        #expect(snapshot.windowTitle == "voxmit — zsh")
    }

    @Test func snapshot_noFocusedWindow_appFieldsOnly() {
        let workspace = MockSystemWorkspace()
        workspace.windowTitle = nil // 无焦点窗口 / 无 AX 权限（同一路径）
        let collector = RealContextCollector(workspace: workspace)

        let snapshot = collector.snapshotTarget()

        // 降级为仅 App 名（§4.2.5）：pid/bundleID/名称仍在，无窗口标题
        #expect(snapshot.pid == 4242)
        #expect(snapshot.bundleID == "com.apple.Terminal")
        #expect(snapshot.appName == "Terminal")
        #expect(snapshot.windowTitle == nil)
    }

    @Test func snapshot_noFrontmostApp_noContextMode() {
        let workspace = MockSystemWorkspace()
        workspace.frontmost = nil // 全失败（如前台取不到）
        let collector = RealContextCollector(workspace: workspace)

        let snapshot = collector.snapshotTarget()

        // 「无上下文」模式：pid 0 + 空标识（润色退化为仅句式整理）
        #expect(snapshot.pid == 0)
        #expect(snapshot.bundleID.isEmpty)
        #expect(snapshot.appName.isEmpty)
        #expect(snapshot.windowTitle == nil)
    }

    @Test func snapshot_noAXPermission_logsDedicatedMessageWithCategory() {
        let workspace = MockSystemWorkspace()
        workspace.frontmost = (7777, "com.test.loga", "日志专用AppA")
        workspace.windowTitle = nil
        let collector = RealContextCollector(
            workspace: workspace,
            axTrustedProvider: { false } // 无辅助功能权限
        )

        _ = collector.snapshotTarget()

        // 路径一：无 AX 权限 → 专属文案 + 分类入日志
        let log = AppLog.recentEntries.last {
            $0.category == "context" && $0.message.contains("日志专用AppA")
        }
        #expect(log?.message.contains("无辅助功能权限，仅记录 App 名") == true)
        #expect(log?.message.contains("分类 other") == true)
    }

    @Test func snapshot_axGrantedButNoWindow_logsDedicatedMessageWithCategory() {
        let workspace = MockSystemWorkspace()
        workspace.frontmost = (8888, "com.apple.Terminal", "日志专用AppB")
        workspace.windowTitle = nil
        let collector = RealContextCollector(
            workspace: workspace,
            axTrustedProvider: { true } // 已授权 AX 但取不到焦点窗口
        )

        _ = collector.snapshotTarget()

        // 路径二：有 AX 无窗口 → 专属文案 + 分类入日志
        let log = AppLog.recentEntries.last {
            $0.category == "context" && $0.message.contains("日志专用AppB")
        }
        #expect(log?.message.contains("已授权 AX 但取不到焦点窗口标题") == true)
        #expect(log?.message.contains("分类 terminal") == true)
    }
}

/// bundleID → AppCategory 适配表（§4.2.5）
struct AppCategoryMapperTests {

    @Test(arguments: [
        ("com.apple.Terminal", AppCategory.terminal),
        ("com.googlecode.iterm2", .terminal),
        ("dev.warp.Warp-Stable", .terminal),
        ("com.microsoft.VSCode", .editor),
        ("com.todesktop.230313mzl4w4u92", .editor),
        ("dev.zed.Zed", .editor),
        ("com.apple.dt.Xcode", .editor),
        ("com.jetbrains.intellij", .editor),
        ("com.jetbrains.AppCode", .editor),
        ("com.apple.Safari", .browser),
        ("com.google.Chrome", .browser),
        ("org.mozilla.firefox", .browser),
        ("com.unknown.app", .other),
        ("", .other),
    ])
    func category_bundleID_mapsCorrectly(bundleID: String, expected: AppCategory) {
        #expect(AppCategoryMapper.category(for: bundleID) == expected)
    }
}

/// 「无上下文」模式的消息组装（§4.2.5 降级：全部失败 → 润色仅做句式整理）
struct RefinePromptNoContextTests {

    @Test func userMessage_emptyAppName_omitsContextBlock() {
        let context = VoiceContext(
            target: TargetSnapshot(pid: 0, bundleID: "", appName: "", windowTitle: nil, capturedAt: Date()),
            appCategory: .other,
            selectedText: nil,
            cliSession: nil
        )

        let message = RefinePrompt.userMessage(raw: "帮我写个函数", context: context)

        #expect(!message.contains("【上下文】"))
        #expect(message.contains("【口述内容】"))
        #expect(message.contains("帮我写个函数"))
    }

    @Test func userMessage_terminalTarget_omitsWindowTitle() {
        let context = VoiceContext(
            target: TargetSnapshot(pid: 1, bundleID: "com.apple.Terminal", appName: "Terminal",
                                   windowTitle: "voxmit — zsh — 200×63", capturedAt: Date()),
            appCategory: .terminal,
            selectedText: nil,
            cliSession: nil
        )

        let message = RefinePrompt.userMessage(raw: "可以了，提交吧", context: context)

        #expect(message.contains("当前 App：Terminal"))
        #expect(!message.contains("窗口标题")) // terminal 窗口标题噪声大，省略防脑补
        #expect(message.contains("可以了，提交吧"))
    }

    @Test func userMessage_nonTerminalTarget_includesWindowTitle() {
        let context = VoiceContext(
            target: TargetSnapshot(pid: 1, bundleID: "com.microsoft.VSCode", appName: "Visual Studio Code",
                                   windowTitle: "voiceprompt — main.swift", capturedAt: Date()),
            appCategory: .editor,
            selectedText: nil,
            cliSession: nil
        )

        let message = RefinePrompt.userMessage(raw: "这个函数为什么报错", context: context)

        #expect(message.contains("当前 App：Visual Studio Code"))
        #expect(message.contains("窗口标题：voiceprompt — main.swift"))
    }
}

/// 松手时前台校验（§3.4.3：以松手时前台为准）
@MainActor
struct PipelineReleaseValidationTests {

    private func settle() async {
        for _ in 0..<12 { await Task { @MainActor in }.value }
    }

    private func snapshot(_ bundleID: String, _ name: String, _ pid: pid_t) -> TargetSnapshot {
        TargetSnapshot(pid: pid, bundleID: bundleID, appName: name, windowTitle: nil,
                       capturedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func keyUp_frontmostSwitched_usesReleaseSnapshotAndLogsNotice() async throws {
        let fixtureClock = MockClock()
        let audio = MockAudioCapture()
        let transcription = MockTranscriptionEngine()
        let refiner = MockRefiner()
        let injector = MockInjector()
        let context = MockContextCollector()
        // 唯一标记名：全局共享 AppLog 环形缓冲会被并行测试写入，名字必须不与其他用例冲突
        let snapshotA = snapshot("com.test.aaa", "AAA旧前台", 100)
        let snapshotB = snapshot("com.microsoft.VSCode", "BBB新前台", 200)
        context.snapshotsToReturn = [snapshotA, snapshotB] // keyDown 取 A、松手取 B

        let pipeline = VoicePipeline(
            clock: fixtureClock,
            audio: audio,
            transcription: transcription,
            refiner: refiner,
            injector: injector,
            contextCollector: context,
            autoSend: { false }
        )
        pipeline.applyPermissionSnapshot(PermissionSnapshot(
            microphone: .authorized, listenEventGranted: true, accessibilityGranted: true
        ))

        pipeline.handleHotkeyDown(bypassModifierActive: false)
        fixtureClock.advance(by: VoicePipeline.confirmationDelay)
        await settle()
        #expect(pipeline.isRecording)

        fixtureClock.advance(by: 0.4)
        pipeline.handleHotkeyUp()
        await settle()
        await settle()

        // 注入与润色都以松手时前台 B 为准（§3.4.3）
        #expect(injector.receivedTarget?.bundleID == "com.microsoft.VSCode")
        #expect(injector.receivedTarget?.pid == 200)
        #expect(refiner.receivedContext?.target.bundleID == "com.microsoft.VSCode")
        // AppCategory 真实分类（VSCode → editor）
        #expect(refiner.receivedContext?.appCategory == .editor)
        // 切换 NOTICE 日志：按唯一标记名定位（全局缓冲内不与其他用例混淆）
        let switchLog = AppLog.recentEntries.first {
            $0.category == "context" && $0.level == .notice
                && $0.message.contains("AAA旧前台") && $0.message.contains("BBB新前台")
        }
        #expect(switchLog != nil)
    }

    @Test func keyUp_frontmostUnchanged_releaseSnapshotUsedForInjection() async throws {
        let fixtureClock = MockClock()
        let audio = MockAudioCapture()
        let context = MockContextCollector()
        let injector = MockInjector()
        let same = snapshot("com.apple.Terminal", "Terminal", 100)
        context.snapshotsToReturn = [same, same]

        let pipeline = VoicePipeline(
            clock: fixtureClock,
            audio: audio,
            transcription: MockTranscriptionEngine(),
            refiner: MockRefiner(),
            injector: injector,
            contextCollector: context,
            autoSend: { false }
        )
        pipeline.applyPermissionSnapshot(PermissionSnapshot(
            microphone: .authorized, listenEventGranted: true, accessibilityGranted: true
        ))

        pipeline.handleHotkeyDown(bypassModifierActive: false)
        fixtureClock.advance(by: VoicePipeline.confirmationDelay)
        await settle()
        fixtureClock.advance(by: 0.4)
        pipeline.handleHotkeyUp()
        await settle()

        // 未切换：注入/润色上下文仍用松手快照（语义一致），Terminal → terminal 分类
        #expect(injector.receivedTarget?.bundleID == "com.apple.Terminal")
    }
}
