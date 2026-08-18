import Combine
import Foundation
import Testing
@testable import Voxmit

/// 状态机测试辅助：按 case 名比较状态序列（recording/failed 带关联值，不便直接等值比较）
private extension VoicePipelineState {
    var caseName: String {
        switch self {
        case .idle: return "idle"
        case .recording: return "recording"
        case .transcribing: return "transcribing"
        case .refining: return "refining"
        case .injecting: return "injecting"
        case .injected: return "injected"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }
}

/// 记录 Pipeline 状态发射序列（@Published 在主 Actor 同步发出，assumeIsolated 安全）
@MainActor
private final class StateRecorder {
    private(set) var names: [String] = []
    private var cancellable: AnyCancellable?

    func attach(to pipeline: VoicePipeline) {
        cancellable = pipeline.$state.sink { [weak self] state in
            MainActor.assumeIsolated { self?.names.append(state.caseName) }
        }
    }
}

/// VoicePipeline 状态机时序全路径（需求文档 §3.4.1 / §3.4.2；mock 时钟与全部下游，零系统权限）
@MainActor
struct VoicePipelineStateMachineTests {

    // MARK: - 测试装置

    @MainActor
    private struct Fixture {
        let clock = MockClock()
        let audio = MockAudioCapture()
        let transcription = MockTranscriptionEngine()
        let refiner = MockRefiner()
        let injector = MockInjector()
        let context = MockContextCollector()
        let recorder = StateRecorder()
        let pipeline: VoicePipeline

        init(autoSend: Bool = false) {
            pipeline = VoicePipeline(
                clock: clock,
                audio: audio,
                transcription: transcription,
                refiner: refiner,
                injector: injector,
                contextCollector: context,
                autoSend: { autoSend }
            )
            // 默认授予全部权限；无权限场景在各自用例里覆盖
            pipeline.applyPermissionSnapshot(PermissionSnapshot(
                microphone: .authorized, listenEventGranted: true, accessibilityGranted: true
            ))
            recorder.attach(to: pipeline)
        }
    }

    /// 让主 Actor 与协作线程池之间排队的任务跑完：探针任务按 FIFO 排在已入队工作之后；
    /// 处理链有多次执行器往返（转写/润色/注入各一次池跳），连续 12 次探针覆盖全部跳转，
    /// 确定性、非定长等待（每次探针微秒级）
    private func settlePipeline() async {
        for _ in 0..<12 {
            await Task { @MainActor in }.value
        }
    }

    /// 进入 recording 状态的公共路径：按下 → 推进 200ms 确认期
    private func enterRecording(_ f: Fixture, bypass: Bool = false) async {
        f.pipeline.handleHotkeyDown(bypassModifierActive: bypass)
        f.clock.advance(by: VoicePipeline.confirmationDelay)
        await settlePipeline()
        #expect(f.pipeline.isRecording)
    }

    // MARK: - 防误触与取消（§3.4.2 / FR-B5）

    @Test func hotkeyDown_releaseWithin200ms_entirelyIgnored() async {
        let f = Fixture()

        f.pipeline.handleHotkeyDown(bypassModifierActive: false)
        f.clock.advance(by: 0.1)
        f.pipeline.handleHotkeyUp()
        await settlePipeline()
        f.clock.advance(by: 0.2) // 确认期任务已被取消，之后不再有任何状态变化
        await settlePipeline()

        #expect(f.recorder.names == ["idle"]) // 只有订阅时的初始值，整次忽略
        #expect(f.audio.startCallCount == 1)  // §4.3：按下即开始采集
        #expect(f.audio.cancelCallCount == 1) // 松开过早：丢弃
        #expect(f.audio.stopCallCount == 0)
        #expect(f.transcription.callCount == 0)
        #expect(f.pipeline.state == .idle)
    }

    @Test func hotkeyUp_recordingShorterThan300ms_cancelledAsMistouch() async {
        let f = Fixture()
        await enterRecording(f)

        f.clock.advance(by: 0.15) // 录音仅 150ms < 300ms
        f.pipeline.handleHotkeyUp()
        await settlePipeline()

        #expect(f.recorder.names == ["idle", "recording", "cancelled", "idle"])
        #expect(f.audio.cancelCallCount == 1) // 误触取消：丢弃而非 stop
        #expect(f.audio.stopCallCount == 0)
        #expect(f.transcription.callCount == 0)
    }

    @Test func escape_duringConfirmationPeriod_cancels() async {
        let f = Fixture()

        f.pipeline.handleHotkeyDown(bypassModifierActive: false)
        f.clock.advance(by: 0.1)
        f.pipeline.cancel()
        await settlePipeline()
        f.clock.advance(by: 0.2) // 确认期任务已取消，不会进入 recording
        await settlePipeline()

        #expect(f.recorder.names == ["idle", "cancelled", "idle"])
        #expect(f.audio.cancelCallCount == 1)
        #expect(f.transcription.callCount == 0)
    }

    @Test func escape_duringRecording_cancelsAndDiscards() async {
        let f = Fixture()
        await enterRecording(f)

        f.pipeline.cancel()
        await settlePipeline()

        #expect(f.recorder.names == ["idle", "recording", "cancelled", "idle"])
        #expect(f.audio.cancelCallCount == 1)
        #expect(f.audio.stopCallCount == 0)
        #expect(f.transcription.callCount == 0)
    }

    @Test func escape_duringProcessing_cancelsChain() async {
        let f = Fixture()
        f.transcription.delay = 60 // 转写挂起 60 虚拟秒，制造"处理中"窗口
        f.transcription.delayClock = f.clock
        await enterRecording(f)

        f.clock.advance(by: 0.4)
        f.pipeline.handleHotkeyUp()
        await settlePipeline()
        #expect(f.pipeline.state == .transcribing)

        f.pipeline.cancel() // Esc：取消进行中的处理 Task
        await settlePipeline()
        #expect(f.recorder.names == ["idle", "recording", "transcribing", "cancelled", "idle"])

        f.clock.advance(by: 120) // 链路已取消，之后不会再推进到注入
        await settlePipeline()
        #expect(f.injector.callCount == 0)
        #expect(f.recorder.names == ["idle", "recording", "transcribing", "cancelled", "idle"])
    }

    // MARK: - 正常流程与边界

    @Test func hotkeyUp_afterValidRecording_completesFullChain() async {
        let f = Fixture(autoSend: true)
        await enterRecording(f, bypass: false)

        f.clock.advance(by: 0.4) // 录音 400ms ≥ 300ms
        f.pipeline.handleHotkeyUp()
        await settlePipeline()
        await settlePipeline()

        #expect(f.recorder.names == ["idle", "recording", "transcribing", "refining", "injecting", "injected", "idle"])
        #expect(f.audio.stopCallCount == 1)
        #expect(f.transcription.receivedSamples == f.audio.samplesToReturn)
        #expect(f.refiner.receivedRaw == "帮我重构这个函数")
        #expect(f.refiner.receivedContext?.target.bundleID == "com.apple.Terminal") // keyDown 快照目标
        #expect(f.injector.receivedText == "润色后的工程 Prompt")
        #expect(f.injector.receivedAutoSend == true)
        #expect(f.context.callCount == 1) // §3.4.3：keyDown 瞬间快照一次
    }

    @Test func hotkeyUp_justUnder300ms_cancels() async {
        // Date 内部以 2001 纪元存储秒数，大基数下 Double 有 ~1e-7 误差，
        // 无法用"恰好 300ms"做断言，以 -1ms 逼近边界（>> 浮点噪声）锁定阈值语义
        let f = Fixture()
        await enterRecording(f)

        f.clock.advance(by: VoicePipeline.minimumRecordingDuration - 0.001)
        f.pipeline.handleHotkeyUp()
        await settlePipeline()

        #expect(f.recorder.names == ["idle", "recording", "cancelled", "idle"])
        #expect(f.injector.callCount == 0)
    }

    @Test func hotkeyUp_justOver300ms_processes() async {
        let f = Fixture()
        await enterRecording(f)

        f.clock.advance(by: VoicePipeline.minimumRecordingDuration + 0.001)
        f.pipeline.handleHotkeyUp()
        await settlePipeline()
        await settlePipeline()

        #expect(f.recorder.names.contains("injected"))
        #expect(f.injector.callCount == 1)
    }

    @Test func bypassModifierAtKeyDown_skipsRefinement() async {
        let f = Fixture()
        await enterRecording(f, bypass: true) // FR-D4：keyDown 瞬间 Shift 已按下

        f.clock.advance(by: 0.4)
        f.pipeline.handleHotkeyUp()
        await settlePipeline()
        await settlePipeline()

        #expect(f.refiner.callCount == 0) // 跳过润色
        #expect(f.injector.receivedText == "帮我重构这个函数") // 直接注入原文
        #expect(f.recorder.names == ["idle", "recording", "transcribing", "injecting", "injected", "idle"])
    }

    @Test func emptyTranscript_silentlyReturnsToIdle() async {
        let f = Fixture()
        f.transcription.result = "" // 空音频/纯静音（§4.2.3）
        await enterRecording(f)

        f.clock.advance(by: 0.4)
        f.pipeline.handleHotkeyUp()
        await settlePipeline()
        await settlePipeline()

        // 静默结束：不报错、不润色、不注入
        #expect(f.recorder.names == ["idle", "recording", "transcribing", "idle"])
        #expect(f.refiner.callCount == 0)
        #expect(f.injector.callCount == 0)
    }

    @Test func processing_trimsLeadingSilenceBeforeTranscription() async {
        let f = Fixture()
        // 1 秒静音前缀（16000 样本 @16kHz）+ 100ms 有效信号（§4.2.2 蓝牙麦场景）
        f.audio.samplesToReturn = [Float](repeating: 0, count: 16000) + [Float](repeating: 0.5, count: 1600)
        await enterRecording(f)

        f.clock.advance(by: 0.4)
        f.pipeline.handleHotkeyUp()
        await settlePipeline()
        await settlePipeline()

        // 转写收到裁剪后数据：静音前缀去掉、保留 50ms（800 样本）前导
        #expect(f.transcription.receivedSamples?.count == 1600 + 800)
    }

    @Test func injectionFailure_entersFailedThenIdle() async {
        let f = Fixture()
        f.injector.outcome = .failed("目标不可注入")
        await enterRecording(f)

        f.clock.advance(by: 0.4)
        f.pipeline.handleHotkeyUp()
        await settlePipeline()
        await settlePipeline()

        #expect(f.recorder.names == ["idle", "recording", "transcribing", "refining", "injecting", "failed", "idle"])
    }

    @Test func clipboardOnlyOutcome_countsAsInjected() async {
        let f = Fixture()
        f.injector.outcome = .clipboardOnly // 注入降级档位（§4.4）按成功处理
        await enterRecording(f)

        f.clock.advance(by: 0.4)
        f.pipeline.handleHotkeyUp()
        await settlePipeline()
        await settlePipeline()

        #expect(f.recorder.names.contains("injected"))
        #expect(!f.recorder.names.contains("failed"))
    }

    // MARK: - 注入报告（HUD 反馈态数据源，Phase 4）

    @Test func fullChain_setsInjectionReportAndPublishesTarget() async {
        let f = Fixture()
        await enterRecording(f)

        f.clock.advance(by: 0.4)
        f.pipeline.handleHotkeyUp()
        await settlePipeline()
        await settlePipeline()

        #expect(f.pipeline.lastInjectionReport == InjectionReport(outcome: .pasted, wasRefined: true))
        #expect(f.pipeline.targetSnapshot?.bundleID == "com.apple.Terminal")
    }

    @Test func bypassModifier_reportMarksUnrefined() async {
        let f = Fixture()
        await enterRecording(f, bypass: true)

        f.clock.advance(by: 0.4)
        f.pipeline.handleHotkeyUp()
        await settlePipeline()
        await settlePipeline()

        #expect(f.pipeline.lastInjectionReport?.outcome == .pasted)
        #expect(f.pipeline.lastInjectionReport?.wasRefined == false)
    }

    @Test func injectionFailure_reportCarriesFailure() async {
        let f = Fixture()
        f.injector.outcome = .failed("目标不可注入")
        await enterRecording(f)

        f.clock.advance(by: 0.4)
        f.pipeline.handleHotkeyUp()
        await settlePipeline()
        await settlePipeline()

        #expect(f.pipeline.lastInjectionReport?.outcome == .failed("目标不可注入"))
    }

    @Test func newRecording_clearsInjectionReport() async {
        let f = Fixture()
        await enterRecording(f)
        f.clock.advance(by: 0.4)
        f.pipeline.handleHotkeyUp()
        await settlePipeline()
        await settlePipeline()
        #expect(f.pipeline.lastInjectionReport != nil)

        f.pipeline.handleHotkeyDown(bypassModifierActive: false)

        #expect(f.pipeline.lastInjectionReport == nil)
    }

    // MARK: - 入口等价性与预留接口

    @Test func maxRecordingDuration_routesToReleaseFlow() async {
        let f = Fixture()
        await enterRecording(f)

        f.clock.advance(by: VoicePipeline.maximumRecordingDuration) // 录满 5 分钟（虚拟）
        f.pipeline.handleMaxRecordingDuration() // FR-A3 入口：按"松手"流程处理已录部分
        await settlePipeline()
        await settlePipeline()

        #expect(f.recorder.names.contains("injected"))
        #expect(f.injector.callCount == 1)
    }

    @Test func menuToggle_behavesLikeHotkeyPath() async {
        let f = Fixture()

        f.pipeline.handleMenuToggle() // 菜单点击开始（无旁路修饰键）
        f.clock.advance(by: VoicePipeline.confirmationDelay)
        await settlePipeline()
        #expect(f.pipeline.isRecording)

        f.clock.advance(by: 0.4)
        f.pipeline.handleMenuToggle() // 再次点击停止 → 同热键松手路径
        await settlePipeline()
        await settlePipeline()

        #expect(f.recorder.names == ["idle", "recording", "transcribing", "refining", "injecting", "injected", "idle"])
        #expect(f.refiner.callCount == 1) // 菜单路径无旁路：正常润色
    }

    @Test func hotkeyDown_whileAlreadyStarting_ignored() async {
        let f = Fixture()

        f.pipeline.handleHotkeyDown(bypassModifierActive: false)
        f.pipeline.handleHotkeyDown(bypassModifierActive: false) // 确认期内重复按下：忽略
        f.clock.advance(by: VoicePipeline.confirmationDelay)
        await settlePipeline()

        #expect(f.audio.startCallCount == 1)
        #expect(f.pipeline.isRecording)
    }

    // MARK: - 权限门控（§4.4）

    @Test func hotkeyDown_withoutMicPermission_failsAndDoesNotRecord() async {
        let f = Fixture()
        f.pipeline.applyPermissionSnapshot(PermissionSnapshot(
            microphone: .denied, listenEventGranted: true, accessibilityGranted: true
        ))

        f.pipeline.handleHotkeyDown(bypassModifierActive: false)
        await settlePipeline()
        f.clock.advance(by: 0.3)
        await settlePipeline()

        #expect(f.recorder.names == ["idle", "failed", "idle"])
        #expect(f.audio.startCallCount == 0)
        #expect(f.context.callCount == 0)
        #expect(f.pipeline.state == .idle)
    }

    @Test func hotkeyDown_audioStartFailure_entersFailed() async {
        struct StartError: Error {}
        let f = Fixture()
        f.audio.startError = StartError()

        f.pipeline.handleHotkeyDown(bypassModifierActive: false)
        await settlePipeline()
        f.clock.advance(by: 0.3)
        await settlePipeline()

        #expect(f.recorder.names == ["idle", "failed", "idle"])
        #expect(f.pipeline.isRecording == false)
    }
}
