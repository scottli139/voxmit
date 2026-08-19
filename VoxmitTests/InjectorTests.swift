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

/// ClipboardInjector（Phase 8 P0）降级/完整流程/竞争保护
struct ClipboardInjectorTests {

    /// 测试装置：共享事件日志 + mock 剪贴板/按键 + 虚拟时钟
    private struct Fixture: Sendable {
        let eventLog: InjectEventLog
        let pasteboard: MockPasteboard
        let keyPoster: MockKeyEventPoster
        let clock: MockClock
        let injector: ClipboardInjector

        init(axTrusted: Bool = true, collapseSetting: Bool = false) {
            let eventLog = InjectEventLog()
            let pasteboard = MockPasteboard(eventLog: eventLog)
            let keyPoster = MockKeyEventPoster(eventLog: eventLog)
            let clock = MockClock()
            self.eventLog = eventLog
            self.pasteboard = pasteboard
            self.keyPoster = keyPoster
            self.clock = clock
            self.injector = ClipboardInjector(
                pasteboard: pasteboard,
                keyPoster: keyPoster,
                clock: clock,
                axTrustedProvider: { axTrusted },
                collapseNewlinesProvider: { collapseSetting }
            )
        }
    }

    private func target(bundleID: String = "com.apple.Terminal", pid: pid_t = 1234, appName: String = "Terminal") -> TargetSnapshot {
        TargetSnapshot(pid: pid, bundleID: bundleID, appName: appName, windowTitle: nil,
                       capturedAt: Date(timeIntervalSince1970: 0))
    }

    /// 让协作线程池里的 inject 任务推进到下一个挂起点（sleep 注册）
    private func yieldUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
    }

    private func yieldMany() async {
        for _ in 0..<100 { await Task.yield() }
    }

    // MARK: - 降级

    @Test func inject_noAXPermission_clipboardOnlyWithoutCaptureOrRestore() async {
        let f = Fixture(axTrusted: false)

        let outcome = await f.injector.inject(text: "hello", into: target(), autoSend: false)

        #expect(outcome == .clipboardOnly)
        #expect(f.pasteboard.captureCallCount == 0)
        #expect(f.pasteboard.writeCallCount == 1)
        #expect(f.pasteboard.restoreCallCount == 0)
        #expect(f.keyPoster.postPasteCallCount == 0)
        #expect(f.keyPoster.postReturnCallCount == 0)
        #expect(f.pasteboard.receivedText == "hello")
    }

    @Test func inject_zeroPID_clipboardOnly() async {
        let f = Fixture(axTrusted: true)

        let outcome = await f.injector.inject(
            text: "hello", into: target(bundleID: "com.apple.Terminal", pid: 0), autoSend: false
        )

        #expect(outcome == .clipboardOnly)
        #expect(f.pasteboard.captureCallCount == 0)
        #expect(f.pasteboard.writeCallCount == 1)
        #expect(f.pasteboard.restoreCallCount == 0)
        #expect(f.keyPoster.postPasteCallCount == 0)
    }

    @Test func inject_emptyBundleID_clipboardOnly() async {
        let f = Fixture(axTrusted: true)

        let outcome = await f.injector.inject(
            text: "hello", into: target(bundleID: "", pid: 1234), autoSend: false
        )

        #expect(outcome == .clipboardOnly)
        #expect(f.pasteboard.captureCallCount == 0)
        #expect(f.pasteboard.writeCallCount == 1)
        #expect(f.pasteboard.restoreCallCount == 0)
        #expect(f.keyPoster.postPasteCallCount == 0)
    }

    // MARK: - 完整流程与顺序

    @Test func inject_authorizedValidTarget_pastesThenRestores() async {
        let f = Fixture(axTrusted: true)

        let task = Task { await f.injector.inject(text: "hello", into: target(), autoSend: false) }
        await yieldUntil { f.eventLog.contains("postPaste") }
        await yieldMany() // 让 sleep(0.3) 在推进虚拟时间前完成注册
        f.clock.advance(by: 0.3)
        let outcome = await task.value

        #expect(outcome == .pasted)
        // capture → write → postPaste → restore（sleep 位于 postPaste 与 restore 之间）
        #expect(f.eventLog.snapshot == ["capture", "write", "postPaste", "restore"])
        #expect(f.pasteboard.captureCallCount == 1)
        #expect(f.pasteboard.writeCallCount == 1)
        #expect(f.pasteboard.restoreCallCount == 1)
        #expect(f.keyPoster.postPasteCallCount == 1)
        #expect(f.keyPoster.postReturnCallCount == 0)
        // restore 使用 write 后返回的 changeCount（非 capture 的 changeCount）
        #expect(f.pasteboard.receivedExpectedChangeCount == f.pasteboard.writeReturn)
    }

    @Test func inject_autoSend_postsReturnAfterSecondDelay() async {
        let f = Fixture(axTrusted: true)

        let task = Task { await f.injector.inject(text: "hi", into: target(), autoSend: true) }
        await yieldUntil { f.eventLog.contains("postPaste") }
        await yieldMany()
        f.clock.advance(by: 0.3) // 首次睡眠 → restore
        await yieldUntil { f.eventLog.contains("restore") }
        await yieldMany() // 让 sleep(0.15) 完成注册
        f.clock.advance(by: 0.15)
        let outcome = await task.value

        #expect(outcome == .pasted)
        #expect(f.eventLog.snapshot == ["capture", "write", "postPaste", "restore", "postReturn"])
        #expect(f.keyPoster.postReturnCallCount == 1)
    }

    // MARK: - 写入失败

    @Test func inject_writeFailure_returnsFailed() async {
        let f = Fixture(axTrusted: true)
        f.pasteboard.writeReturn = nil

        let outcome = await f.injector.inject(text: "hello", into: target(), autoSend: false)

        #expect(outcome == .failed("剪贴板写入失败"))
        #expect(f.pasteboard.captureCallCount == 1) // 完整流程先快照再写
        #expect(f.pasteboard.writeCallCount == 1)
        #expect(f.keyPoster.postPasteCallCount == 0)
        #expect(f.pasteboard.restoreCallCount == 0)
    }

    // MARK: - changeCount 竞争保护

    @Test func inject_restoreConflict_stillPasted() async {
        let f = Fixture(axTrusted: true)
        f.pasteboard.restoreReturn = false // 模拟恢复期间用户改写了剪贴板

        let task = Task { await f.injector.inject(text: "hello", into: target(), autoSend: false) }
        await yieldUntil { f.eventLog.contains("postPaste") }
        await yieldMany()
        f.clock.advance(by: 0.3)
        let outcome = await task.value

        // 竞争放弃恢复不改注入结果：文本已送达，仅剪贴板保持用户最新内容
        #expect(outcome == .pasted)
        #expect(f.pasteboard.restoreCallCount == 1)
    }

    // MARK: - 换行折叠

    @Test func inject_terminalCollapseEnabled_writesCollapsedText() async {
        let f = Fixture(axTrusted: false, collapseSetting: true)

        let outcome = await f.injector.inject(
            text: "第一行\n第二行\r\n第三行\r第四行",
            into: target(bundleID: "com.apple.Terminal"),
            autoSend: false
        )

        #expect(outcome == .clipboardOnly)
        #expect(f.pasteboard.receivedText == "第一行 第二行 第三行 第四行")
    }

    @Test func inject_editorTarget_doesNotCollapse() async {
        let f = Fixture(axTrusted: false, collapseSetting: true)
        let original = "第一行\n第二行"

        let outcome = await f.injector.inject(
            text: original,
            into: target(bundleID: "com.microsoft.VSCode"),
            autoSend: false
        )

        #expect(outcome == .clipboardOnly)
        #expect(f.pasteboard.receivedText == original)
    }
}
