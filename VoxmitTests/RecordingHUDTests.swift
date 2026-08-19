import Foundation
import Testing
@testable import Voxmit

/// HUD 布局尺寸钳制（长文案换行修复）
struct HUDLayoutTests {

    @Test func clampedSize_belowMinimum_clampedToFloor() {
        let size = HUDLayout.clampedSize(NSSize(width: 0, height: 0))
        #expect(size.width == HUDLayout.minWidth)
        #expect(size.height == HUDLayout.minHeight)
    }

    @Test func clampedSize_withinRange_unchanged() {
        let size = HUDLayout.clampedSize(NSSize(width: 300, height: 60))
        #expect(size.width == 300)
        #expect(size.height == 60)
    }

    @Test func clampedSize_overMaxWidth_capped() {
        // 超宽内容（不换行的极端情况）被压到上限
        let size = HUDLayout.clampedSize(NSSize(width: 900, height: 60))
        #expect(size.width == HUDLayout.maxWidth)
    }

    @Test func clampedSize_tallContent_heightNotCapped() {
        // 换行撑高不限制高度上限（只钳最小值）
        let size = HUDLayout.clampedSize(NSSize(width: 300, height: 200))
        #expect(size.height == 200)
    }

    @Test func textColumnFitsPanelBounds() {
        // 文案列宽上限 + 图标 + 内边距 不超出面板宽度上限（防布局溢出）
        #expect(HUDLayout.textColumnMaxWidth + 100 <= HUDLayout.maxWidth)
    }
}

/// 波形区几何（限宽滚动窗口，不溢出盖字）
struct WaveformLayoutTests {

    @Test func visibleCapacity_fitsFrame() {
        // 容量 × 条宽 + (容量-1) × 间距 不超过可视宽度（真机 bug：24 条溢出盖到文字上）
        let capacity = WaveformLayout.visibleCapacity
        let used = CGFloat(capacity) * WaveformLayout.barWidth
            + CGFloat(capacity - 1) * WaveformLayout.spacing
        #expect(used <= WaveformLayout.width)
        // 再加一条必然超出 → 当前容量即上限
        let oneMore = used + WaveformLayout.barWidth + WaveformLayout.spacing
        #expect(oneMore > WaveformLayout.width)
        #expect(capacity == 17)
    }

    @Test func visibleBars_overCapacity_keepsNewest() {
        // 24 条历史（LevelHistory.capacity）只画最近 17 条，旧条淘汰
        let bars = (0..<LevelHistory.capacity).map { Float($0) }
        let visible = WaveformLayout.visibleBars(bars)
        #expect(visible.count == WaveformLayout.visibleCapacity)
        #expect(visible.first == Float(LevelHistory.capacity - WaveformLayout.visibleCapacity))
        #expect(visible.last == bars.last)
    }

    @Test func visibleBars_underCapacity_keepsAll() {
        let visible = WaveformLayout.visibleBars([0.1, 0.5, 0.9])
        #expect(visible == [0.1, 0.5, 0.9])
    }
}

/// HUD 显示策略（HUDVisibility，纯逻辑）
struct HUDVisibilityTests {

    private let refinedPasted = InjectionReport(outcome: .pasted, wasRefined: true)
    private let unrefinedPasted = InjectionReport(outcome: .pasted, wasRefined: false)
    private let clipboardOnly = InjectionReport(outcome: .clipboardOnly, wasRefined: true)

    @Test func hideDelay_activeStates_staysVisible() {
        #expect(HUDVisibility.hideDelay(for: .recording(startedAt: Date()), report: nil) == nil)
        #expect(HUDVisibility.hideDelay(for: .transcribing, report: nil) == nil)
        #expect(HUDVisibility.hideDelay(for: .refining, report: nil) == nil)
        #expect(HUDVisibility.hideDelay(for: .injecting, report: nil) == nil)
    }

    @Test func hideDelay_injected_successShortLinger() {
        #expect(HUDVisibility.hideDelay(for: .injected, report: refinedPasted) == HUDVisibility.successDuration)
    }

    @Test func hideDelay_injectedUnrefined_longerLinger() {
        #expect(HUDVisibility.hideDelay(for: .injected, report: unrefinedPasted) == HUDVisibility.unrefinedDuration)
    }

    @Test func hideDelay_clipboardOnly_readingTime() {
        // "已复制，Cmd+V 手动粘贴"需要阅读时间
        #expect(HUDVisibility.hideDelay(for: .injected, report: clipboardOnly) == HUDVisibility.clipboardOnlyDuration)
        #expect(HUDVisibility.clipboardOnlyDuration > HUDVisibility.successDuration)
    }

    @Test func hideDelay_injectedWithoutReport_defaultsToSuccess() {
        #expect(HUDVisibility.hideDelay(for: .injected, report: nil) == HUDVisibility.successDuration)
    }

    @Test func hideDelay_failed_failureLinger() {
        #expect(HUDVisibility.hideDelay(for: .failed("原因"), report: nil) == HUDVisibility.failureDuration)
    }

    @Test func hideDelay_cancelledAndIdle_hideImmediately() {
        #expect(HUDVisibility.hideDelay(for: .cancelled, report: nil) == 0)
        #expect(HUDVisibility.hideDelay(for: .idle, report: nil) == 0)
    }
}

/// 波形历史（LevelHistory，纯逻辑）
struct LevelHistoryTests {

    @Test func push_normalizesDecibelsToUnit() {
        var history = LevelHistory()
        history.push(decibels: 0)     // 满格
        history.push(decibels: -30)   // 一半
        history.push(decibels: -60)   // 地板
        history.push(decibels: -120)  // 地板以下按 0
        #expect(history.bars == [1, 0.5, 0, 0])
    }

    @Test func push_clampsAboveZero() {
        var history = LevelHistory()
        history.push(decibels: 5) // 异常大于 0dB 也钳到 1
        #expect(history.bars == [1])
    }

    @Test func push_capsAtCapacity() {
        var history = LevelHistory()
        for _ in 0..<(LevelHistory.capacity + 10) {
            history.push(decibels: -30)
        }
        #expect(history.bars.count == LevelHistory.capacity)
    }

    @Test func reset_clearsBars() {
        var history = LevelHistory()
        history.push(decibels: -30)
        history.reset()
        #expect(history.bars.isEmpty)
    }
}

/// 音频事件 → HUD 提示文案
struct HUDBannerTests {

    @Test func bannerText_mapping() {
        #expect(RecordingHUDViewModel.bannerText(for: .maxDurationReached) == "已达最长录音时长")
        #expect(RecordingHUDViewModel.bannerText(for: .inputDeviceFellBackToDefault) == "指定麦克风已断开，已切换系统默认")
        #expect(RecordingHUDViewModel.bannerText(for: .captureInterrupted) == "采集中断，已保留已录部分")
    }
}

/// HUD 视图模型（Pipeline + AudioCapture 驱动）
@MainActor
struct RecordingHUDViewModelTests {

    @MainActor
    private struct Fixture {
        let clock = MockClock()
        let audio = MockAudioCapture()
        let transcription = MockTranscriptionEngine()
        let refiner = MockRefiner()
        let injector = MockInjector()
        let context = MockContextCollector()
        let audioCapture = AudioCapture()
        let pipeline: VoicePipeline
        let model: RecordingHUDViewModel

        init() {
            pipeline = VoicePipeline(
                clock: clock,
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
            model = RecordingHUDViewModel(pipeline: pipeline, audioCapture: audioCapture)
        }

        func settle() async {
            for _ in 0..<12 {
                await Task { @MainActor in }.value
            }
        }

        func enterRecording() async {
            pipeline.handleHotkeyDown(bypassModifierActive: false)
            clock.advance(by: VoicePipeline.confirmationDelay)
            await settle()
        }

        func finishRecording() async {
            clock.advance(by: 0.4)
            pipeline.handleHotkeyUp()
            await settle()
            await settle()
        }
    }

    @Test func recording_showsStatusAndTarget() async {
        let f = Fixture()
        await f.enterRecording()

        #expect(f.model.statusText == "正在录音")
        #expect(f.model.feedback == .none)
        #expect(f.model.targetAppName == "Terminal")
    }

    @Test func injectedRefined_successFeedback() async {
        let f = Fixture()
        await f.enterRecording()
        await f.finishRecording()

        #expect(f.model.statusText == "已注入")
        #expect(f.model.feedback == .success)
        #expect(!f.model.showsUnrefinedBadge)
    }

    @Test func clipboardOnly_manualPasteMessage() async {
        let f = Fixture()
        f.injector.outcome = .clipboardOnly
        await f.enterRecording()
        await f.finishRecording()

        #expect(f.model.statusText == "已复制，Cmd+V 手动粘贴")
        #expect(f.model.feedback == .manualPaste)
    }

    @Test func unrefined_showsBadge() async {
        let f = Fixture()
        f.refiner.refinedFlag = false // 润色回退原文
        await f.enterRecording()
        await f.finishRecording()

        #expect(f.model.statusText == "已注入")
        #expect(f.model.showsUnrefinedBadge)
    }

    @Test func failed_showsReason() async {
        let f = Fixture()
        f.injector.outcome = .failed("目标不可注入")
        await f.enterRecording()
        await f.finishRecording()

        #expect(f.model.statusText == "失败：目标不可注入")
        #expect(f.model.feedback == .failure)
    }

    @Test func levels_pushNormalizedBarsAndResetOnNewRecording() async {
        let f = Fixture()

        f.audioCapture.levels.send(-30)
        f.audioCapture.levels.send(-60)
        await f.settle()
        #expect(f.model.levelHistory.bars == [0.5, 0])

        await f.enterRecording() // 新录音重置波形
        #expect(f.model.levelHistory.bars.isEmpty)
    }

    @Test func audioEvents_setBannerAndClearOnNewRecording() async {
        let f = Fixture()

        f.audioCapture.events.send(.maxDurationReached)
        await f.settle()
        #expect(f.model.banner == "已达最长录音时长")

        await f.enterRecording()
        #expect(f.model.banner == nil)
    }
}
