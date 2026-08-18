import Combine
import Foundation

/// 主链路状态机协调器（需求文档 §4.2.0 / §3.4.1）
///
/// 时序判定集中在此层（§4.2.0）：200ms 防误触、300ms 误触取消、Esc 取消、
/// 旁路修饰键判定；HotkeyManager 只上报原始按下/松开事件。
/// 下游模块（音频/转写/润色/注入/上下文）以协议注入，Phase 2 用占位实现接线
/// （见 PlaceholderServices.swift），真实实现随 Phase 3/5/6/7/8 替换。
@MainActor
final class VoicePipeline: ObservableObject {

    // MARK: - 时序常量（需求文档 §3.4.2 / FR-A3）

    /// 按下确认阈值：200ms 内松开整次忽略（防切输入法等误触）
    static let confirmationDelay: TimeInterval = 0.2
    /// 最短录音时长：进入 recording 后不足 300ms 即松开，按误触取消
    static let minimumRecordingDuration: TimeInterval = 0.3
    /// 单次录音上限 5 分钟（FR-A3；计时在 AudioCapture，Phase 3 实装后回调 handleMaxRecordingDuration）
    static let maximumRecordingDuration: TimeInterval = 300

    // MARK: - 对外状态

    /// 当前主链路状态；迁移只允许由协调器内部发起
    @Published private(set) var state: VoicePipelineState = .idle

    /// 当前权限快照，由 PermissionManager 实时同步（VoxmitAppDelegate 中 Combine 接线）。
    /// 降级决策数据源（需求文档 §4.4）：热键降级见 HotkeyManager，注入降级在 Phase 8 接线。
    @Published private(set) var permissionSnapshot: PermissionSnapshot = .unknown

    /// 全局热键是否可用；无输入监控权限时降级为菜单栏点击开始/停止录音
    var canUseGlobalHotkey: Bool { permissionSnapshot.canUseGlobalHotkey }

    /// 注入能力档位；无辅助功能权限时降级为仅剪贴板（Phase 8 接线）
    var injectionCapability: InjectionCapability { permissionSnapshot.injectionCapability }

    /// 是否处于录音中（供菜单栏降级入口切换"开始/停止"文案）
    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    // MARK: - 依赖（协议注入，单测 mock）

    private let clock: any PipelineClock
    private let audio: any AudioCapturing
    private let transcription: any TranscriptionEngine
    private let refiner: any PromptRefining
    private let injector: any TextInjecting
    private let contextCollector: any ContextCollecting
    private let autoSendProvider: () -> Bool

    // MARK: - 会话内部状态

    /// 200ms 确认期起点；非 nil 表示处于确认期（公开状态仍为 idle）
    private var pendingStart: Date?
    private var pendingTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    /// 本次是否跳过润色（FR-D4：keyDown 瞬间旁路修饰键处于按下）
    private var skipRefinement = false
    /// keyDown 瞬间的注入目标快照（§3.4.3；Phase 7 实装真实采集，当前为占位数据）
    @Published private(set) var targetSnapshot: TargetSnapshot?

    /// 最近一次注入的结果摘要（HUD 反馈态显示用，Phase 4）；下次 keyDown 时清空
    @Published private(set) var lastInjectionReport: InjectionReport?

    init(
        clock: any PipelineClock = SystemPipelineClock(),
        audio: any AudioCapturing = NoOpAudioCapture(),
        transcription: any TranscriptionEngine = PlaceholderTranscriptionEngine(),
        refiner: any PromptRefining = NoOpPromptRefiner(),
        injector: any TextInjecting = PlaceholderClipboardInjector(),
        contextCollector: any ContextCollecting = PlaceholderContextCollector(),
        autoSend: @escaping () -> Bool = { UserDefaults.standard.bool(forKey: SettingsKeys.injectAutoSend) }
    ) {
        self.clock = clock
        self.audio = audio
        self.transcription = transcription
        self.refiner = refiner
        self.injector = injector
        self.contextCollector = contextCollector
        self.autoSendProvider = autoSend
    }

    // MARK: - 事件入口（§4.2.0 接口）

    /// 热键按下；bypassModifierActive = keyDown 瞬间旁路修饰键（默认 Shift）已按下（FR-D4）
    func handleHotkeyDown(bypassModifierActive: Bool) {
        guard pendingStart == nil, case .idle = state else { return }
        guard permissionSnapshot.canRecord else {
            finish(with: .failed("未授予麦克风权限"))
            return
        }
        // 按下瞬间：快照注入目标（§3.4.3）并立即开始采集（§4.3，避免丢失开头百毫秒语音）
        targetSnapshot = contextCollector.snapshotTarget()
        lastInjectionReport = nil
        skipRefinement = bypassModifierActive
        do {
            try audio.start()
        } catch {
            finish(with: .failed("无法开始录音：\(error.localizedDescription)"))
            return
        }
        let start = clock.now
        pendingStart = start
        pendingTask = Task { [weak self] in
            guard let self else { return }
            do {
                // 截止时间锚定在 keyDown 时刻（而非任务实际被调度的时刻），
                // 虚拟时钟测试与真实运行语义一致
                let remaining = Self.confirmationDelay - clock.now.timeIntervalSince(start)
                try await clock.sleep(for: max(0, remaining))
            } catch {
                return // 确认期内被取消（提前松开走整次忽略；Esc 走 cancel）
            }
            // 确认期内已松开/取消则 pendingStart 已被清空
            guard pendingStart != nil else { return }
            pendingStart = nil
            pendingTask = nil
            state = .recording(startedAt: clock.now)
        }
    }

    /// 热键松开
    func handleHotkeyUp() {
        // 确认期内松开：整次忽略（§3.4.2），静默丢弃，无状态变化
        if pendingStart != nil {
            pendingTask?.cancel()
            pendingTask = nil
            pendingStart = nil
            audio.cancel()
            return
        }
        guard case .recording(let startedAt) = state else { return }
        // 录音不足 300ms：按误触取消（§3.4.2）
        guard clock.now.timeIntervalSince(startedAt) >= Self.minimumRecordingDuration else {
            audio.cancel()
            finish(with: .cancelled)
            return
        }
        // §3.4.3：录音期间切换前台 App 的场景以松手时前台重新校验目标——Phase 7 实装，当前沿用 keyDown 快照
        startProcessing(target: targetSnapshot ?? contextCollector.snapshotTarget())
    }

    /// Esc 取消（FR-B5）与误触取消统一入口（§4.2.0）；确认期/录音中/处理中均可取消
    func cancel() {
        if pendingStart != nil {
            pendingTask?.cancel()
            pendingTask = nil
            pendingStart = nil
            audio.cancel()
            finish(with: .cancelled)
            return
        }
        if case .recording = state {
            audio.cancel()
            finish(with: .cancelled)
            return
        }
        // 处理中：取消进行中的 Task，终止态由 processRecording 的取消分支收尾
        processingTask?.cancel()
    }

    /// 菜单栏降级入口（无输入监控权限时，§4.4）：点击切换开始/停止，与热键路径等价
    func handleMenuToggle() {
        if isRecording {
            handleHotkeyUp()
        } else {
            handleHotkeyDown(bypassModifierActive: false)
        }
    }

    /// 单次录音达 5 分钟上限（FR-A3）的入口；计时在 AudioCapture（Phase 3 实装），
    /// 到点按"松手"流程处理已录部分；HUD 提示随 Phase 4 实装
    func handleMaxRecordingDuration() {
        handleHotkeyUp()
    }

    /// 更新权限快照；仅 VoxmitAppDelegate 的 Combine 接线与单测调用
    func applyPermissionSnapshot(_ snapshot: PermissionSnapshot) {
        permissionSnapshot = snapshot
    }

    // MARK: - 内部

    private func startProcessing(target: TargetSnapshot) {
        let skip = skipRefinement
        processingTask = Task { [weak self] in
            guard let self else { return }
            await self.processRecording(target: target, skipRefinement: skip)
        }
    }

    /// 松手后的处理链（§4.3）：转写 → 润色 → 注入，全程可取消（Esc 取消进行中的 Task）
    private func processRecording(target: TargetSnapshot, skipRefinement: Bool) async {
        // 蓝牙麦协商延迟等造成的开头静音：转写前裁剪（§4.2.2）
        let samples = SilenceTrimmer.trimLeadingSilence(audio.stop())
        state = .transcribing
        do {
            let raw = try await transcription.transcribe(samples: samples)
            try Task.checkCancellation()
            // 空音频/纯静音：按误触静默结束，不报错、不注入（§4.2.3）
            guard !raw.isEmpty else {
                state = .idle
                return
            }

            let finalText: String
            var wasRefined = false
            if skipRefinement {
                finalText = raw // FR-D4 旁路：跳过润色，直接注入原始转写
            } else {
                state = .refining
                // AppCategory 分类表在 Phase 7 实装，当前固定 .other
                let context = VoiceContext(target: target, appCategory: .other, selectedText: nil, cliSession: nil)
                let result = await refiner.refine(raw: raw, context: context)
                finalText = result.text
                wasRefined = result.refined
                try Task.checkCancellation()
            }

            state = .injecting
            let outcome = await injector.inject(text: finalText, into: target, autoSend: autoSendProvider())
            try Task.checkCancellation()
            // HUD 反馈态数据源（Phase 4）：档位 + 是否实际润色（"未润色"角标）
            lastInjectionReport = InjectionReport(outcome: outcome, wasRefined: wasRefined)
            switch outcome {
            case .failed(let reason):
                finish(with: .failed(reason))
            default:
                finish(with: .injected)
            }
        } catch is CancellationError {
            finish(with: .cancelled)
        } catch {
            finish(with: .failed(error.localizedDescription))
        }
    }

    /// 进入终止态后立即回到 idle（§3.4.1 回退箭头；HUD 反馈与停留时长在 Phase 4 实装）
    private func finish(with terminal: VoicePipelineState) {
        state = terminal
        state = .idle
    }

    /// 菜单栏图标的 SF Symbols 名称，随 state 变化
    var menuBarIcon: String {
        switch state {
        case .idle:
            return "waveform"
        case .recording:
            return "waveform.circle.fill"
        case .transcribing, .refining, .injecting:
            return "ellipsis.circle"
        case .injected:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle"
        case .cancelled:
            return "xmark.circle"
        }
    }

    /// 菜单栏菜单中展示的当前状态文本
    var statusText: String {
        switch state {
        case .idle:
            return "空闲"
        case .recording:
            return "录音中…"
        case .transcribing:
            return "转写中…"
        case .refining:
            return "润色中…"
        case .injecting:
            return "注入中…"
        case .injected:
            return "已注入"
        case .failed(let reason):
            return "失败：\(reason)"
        case .cancelled:
            return "已取消"
        }
    }
}
