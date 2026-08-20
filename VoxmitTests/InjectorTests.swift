import Foundation
import Testing
@testable import Voxmit

/// 注入适配纯逻辑（换行折叠）
struct InjectionAdapterTests {

    @Test func collapseNewlines_replacesAllLineBreakVariantsWithSingleSpace() {
        #expect(InjectionAdapter.collapseNewlines("a\nb") == "a b")
        #expect(InjectionAdapter.collapseNewlines("a\r\nb") == "a b")
        #expect(InjectionAdapter.collapseNewlines("a\rb") == "a b")
        #expect(InjectionAdapter.collapseNewlines("a\r\nb\nc\rd") == "a b c d")
    }

    @Test func collapseNewlines_noNewlines_returnsOriginalFaithfully() {
        #expect(InjectionAdapter.collapseNewlines("hello world") == "hello world")
        // 只折叠换行，不压缩其他空白
        #expect(InjectionAdapter.collapseNewlines("  spaced  ") == "  spaced  ")
    }

    @Test func shouldCollapseNewlines_decidesByCategoryAndSetting() {
        #expect(InjectionAdapter.shouldCollapseNewlines(category: .terminal, settingEnabled: true))
        #expect(!InjectionAdapter.shouldCollapseNewlines(category: .terminal, settingEnabled: false))
        #expect(!InjectionAdapter.shouldCollapseNewlines(category: .editor, settingEnabled: true))
        #expect(!InjectionAdapter.shouldCollapseNewlines(category: .browser, settingEnabled: true))
        #expect(!InjectionAdapter.shouldCollapseNewlines(category: .other, settingEnabled: true))
    }
}

/// ClipboardInjector（Phase 8 P0）降级/完整流程/竞争保护。
/// inject 为 @MainActor 同步方法：主体同步完成，延迟恢复经 `InjectorDelaying.schedule`
/// 主线程调度（零 async await、零跨执行器 hop，真机修复，见 implementation-notes）。
@MainActor
struct ClipboardInjectorTests {

    /// 测试装置：共享事件日志 + mock 剪贴板/按键/延迟调度器
    @MainActor
    private struct Fixture: Sendable {
        let eventLog: InjectEventLog
        let pasteboard: MockPasteboard
        let keyPoster: MockKeyEventPoster
        let delayer: MockInjectorDelayer
        let injector: ClipboardInjector

        init(axTrusted: Bool = true, collapseSetting: Bool = false) {
            let eventLog = InjectEventLog()
            let pasteboard = MockPasteboard(eventLog: eventLog)
            let keyPoster = MockKeyEventPoster(eventLog: eventLog)
            let delayer = MockInjectorDelayer()
            self.eventLog = eventLog
            self.pasteboard = pasteboard
            self.keyPoster = keyPoster
            self.delayer = delayer
            self.injector = ClipboardInjector(
                pasteboard: pasteboard,
                keyPoster: keyPoster,
                delayer: delayer,
                axTrustedProvider: { axTrusted },
                collapseNewlinesProvider: { collapseSetting }
            )
        }
    }

    private func target(bundleID: String = "com.apple.Terminal", pid: pid_t = 1234, appName: String = "Terminal") -> TargetSnapshot {
        TargetSnapshot(pid: pid, bundleID: bundleID, appName: appName, windowTitle: nil,
                       capturedAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: - 降级

    @Test func inject_noAXPermission_clipboardOnlyWithoutCaptureOrRestore() {
        let f = Fixture(axTrusted: false)

        let outcome = f.injector.inject(text: "hello", into: target(), autoSend: false)

        #expect(outcome == .clipboardOnly)
        #expect(f.pasteboard.captureCallCount == 0)
        #expect(f.pasteboard.writeCallCount == 1)
        #expect(f.pasteboard.restoreCallCount == 0)
        #expect(f.keyPoster.postPasteCallCount == 0)
        #expect(f.keyPoster.postReturnCallCount == 0)
        #expect(f.pasteboard.receivedText == "hello")
        #expect(f.delayer.scheduled.isEmpty)
    }

    @Test func inject_zeroPID_clipboardOnly() {
        let f = Fixture(axTrusted: true)

        let outcome = f.injector.inject(
            text: "hello", into: target(bundleID: "com.apple.Terminal", pid: 0), autoSend: false
        )

        #expect(outcome == .clipboardOnly)
        #expect(f.pasteboard.captureCallCount == 0)
        #expect(f.pasteboard.writeCallCount == 1)
        #expect(f.pasteboard.restoreCallCount == 0)
        #expect(f.keyPoster.postPasteCallCount == 0)
    }

    @Test func inject_emptyBundleID_clipboardOnly() {
        let f = Fixture(axTrusted: true)

        let outcome = f.injector.inject(
            text: "hello", into: target(bundleID: "", pid: 1234), autoSend: false
        )

        #expect(outcome == .clipboardOnly)
        #expect(f.pasteboard.captureCallCount == 0)
        #expect(f.pasteboard.writeCallCount == 1)
        #expect(f.pasteboard.restoreCallCount == 0)
        #expect(f.keyPoster.postPasteCallCount == 0)
    }

    // MARK: - 完整流程与顺序

    @Test func inject_authorizedValidTarget_pastesThenRestores() {
        let f = Fixture(axTrusted: true)

        let outcome = f.injector.inject(text: "hello", into: target(), autoSend: false)

        #expect(outcome == .pasted)
        // 主体同步完成：capture → write → postPaste 已发生；restore 已调度未执行
        #expect(f.eventLog.snapshot == ["capture", "write", "postPaste"])
        #expect(f.delayer.scheduled.map(\.delay) == [0.3])
        f.delayer.fireAll()
        #expect(f.eventLog.snapshot == ["capture", "write", "postPaste", "restore"])
        #expect(f.pasteboard.captureCallCount == 1)
        #expect(f.pasteboard.writeCallCount == 1)
        #expect(f.pasteboard.restoreCallCount == 1)
        #expect(f.keyPoster.postPasteCallCount == 1)
        #expect(f.keyPoster.postReturnCallCount == 0)
        // restore 使用 write 后返回的 changeCount（非 capture 的 changeCount）
        #expect(f.pasteboard.receivedExpectedChangeCount == f.pasteboard.writeReturn)
    }

    @Test func inject_autoSend_postsReturnAfterSecondDelay() {
        let f = Fixture(axTrusted: true)

        let outcome = f.injector.inject(text: "hi", into: target(), autoSend: true)

        #expect(outcome == .pasted)
        f.delayer.fireAll() // 执行 restore，并 schedule postReturn
        f.delayer.fireAll() // 执行 postReturn
        #expect(f.eventLog.snapshot == ["capture", "write", "postPaste", "restore", "postReturn"])
        #expect(f.keyPoster.postReturnCallCount == 1)
    }

    // MARK: - 写入失败

    @Test func inject_writeFailure_returnsFailed() {
        let f = Fixture(axTrusted: true)
        f.pasteboard.writeReturn = nil

        let outcome = f.injector.inject(text: "hello", into: target(), autoSend: false)

        #expect(outcome == .failed("剪贴板写入失败"))
        #expect(f.pasteboard.captureCallCount == 1) // 完整流程先快照再写
        #expect(f.pasteboard.writeCallCount == 1)
        #expect(f.keyPoster.postPasteCallCount == 0)
        #expect(f.pasteboard.restoreCallCount == 0)
        #expect(f.delayer.scheduled.isEmpty)
    }

    // MARK: - changeCount 竞争保护

    @Test func inject_restoreConflict_stillPasted() {
        let f = Fixture(axTrusted: true)
        f.pasteboard.restoreReturn = false // 模拟恢复期间用户改写了剪贴板

        let outcome = f.injector.inject(text: "hello", into: target(), autoSend: false)
        f.delayer.fireAll()

        // 竞争放弃恢复不改注入结果：文本已送达，仅剪贴板保持用户最新内容
        #expect(outcome == .pasted)
        #expect(f.pasteboard.restoreCallCount == 1)
    }

    // MARK: - 换行折叠

    @Test func inject_terminalCollapseEnabled_writesCollapsedText() {
        let f = Fixture(axTrusted: false, collapseSetting: true)

        let outcome = f.injector.inject(
            text: "第一行\n第二行\r\n第三行\r第四行",
            into: target(bundleID: "com.apple.Terminal"),
            autoSend: false
        )

        #expect(outcome == .clipboardOnly)
        #expect(f.pasteboard.receivedText == "第一行 第二行 第三行 第四行")
    }

    @Test func inject_editorTarget_doesNotCollapse() {
        let f = Fixture(axTrusted: false, collapseSetting: true)
        let original = "第一行\n第二行"

        let outcome = f.injector.inject(
            text: original,
            into: target(bundleID: "com.microsoft.VSCode"),
            autoSend: false
        )

        #expect(outcome == .clipboardOnly)
        #expect(f.pasteboard.receivedText == original)
    }
}
