import AppKit
import Combine
import SwiftUI

// 录音 HUD（需求文档 §3.4.1 状态反馈 / FR-A2 波形 / FR-F5 降级提示）
//
// 设计要点：
// - 非激活面板（NSPanel + .nonactivatingPanel）：录音时焦点必须留在目标 App，硬要求；
// - 状态机终止态（injected/failed/cancelled）保持"即刻回 idle"不变，
//   停留计时在 HUD 侧（HUDVisibility 纯逻辑决策 + Controller 按时钟调度）；
// - levels 从音频线程发布，ViewModel 订阅时 receive(on:) 主线程。

/// HUD 显示策略（纯逻辑可单测）：给定状态与注入报告，决定 HUD 何时隐藏
enum HUDVisibility {
    /// 注入成功（对勾，自动淡出）
    static let successDuration: TimeInterval = 0.8
    /// 成功但未润色（角标提示，稍长以便用户注意）
    static let unrefinedDuration: TimeInterval = 1.2
    /// 降级仅剪贴板（"已复制，Cmd+V 手动粘贴"需阅读时间）
    static let clipboardOnlyDuration: TimeInterval = 2.5
    /// 失败原因停留
    static let failureDuration: TimeInterval = 2.5

    /// 返回 HUD 应在多久后隐藏；nil = 保持显示
    static func hideDelay(for state: VoicePipelineState, report: InjectionReport?) -> TimeInterval? {
        switch state {
        case .recording, .transcribing, .refining, .injecting:
            return nil
        case .injected:
            if report?.outcome == .clipboardOnly {
                return clipboardOnlyDuration
            }
            return (report?.wasRefined ?? true) ? successDuration : unrefinedDuration
        case .failed:
            return failureDuration
        case .cancelled, .idle:
            return 0 // 取消静默消失；空音频等静默结束立即隐藏
        }
    }
}

/// 波形历史（FR-A2）：保留最近 N 个 dBFS 电平并归一化到 [0,1] 供条形图显示
struct LevelHistory: Equatable {
    /// 保留条数（约 1.2 秒，50ms 一条）
    static let capacity = 24
    /// 显示地板：低于 -60dBFS 视为无信号
    static let displayFloor: Float = -60

    private(set) var bars: [Float] = []

    mutating func push(decibels db: Float) {
        let normalized = min(1, max(0, (db - Self.displayFloor) / (0 - Self.displayFloor)))
        bars.append(normalized)
        if bars.count > Self.capacity {
            bars.removeFirst(bars.count - Self.capacity)
        }
    }

    mutating func reset() {
        bars.removeAll()
    }
}

/// HUD 反馈类别（图标与配色依据）
enum HUDFeedback: Equatable {
    case none          // 录音/处理中
    case success       // 注入成功
    case manualPaste   // 降级仅剪贴板
    case failure       // 失败
}

private extension VoicePipelineState {
    /// 终止反馈态（injected/failed/cancelled）：HUD 展示需锁存，不被紧随的 idle 清空
    var isTerminalFeedback: Bool {
        switch self {
        case .injected, .failed, .cancelled:
            return true
        case .idle, .recording, .transcribing, .refining, .injecting:
            return false
        }
    }
}

/// HUD 布局常量与尺寸钳制（纯逻辑可单测）
enum HUDLayout {
    static let minWidth: CGFloat = 160
    /// 面板宽度上限（长文案在此宽度内换行展示）
    static let maxWidth: CGFloat = 420
    static let minHeight: CGFloat = 44
    /// 文案列宽上限：长句（如失败原因指引）按此换行，2–3 行内完整可读
    static let textColumnMaxWidth: CGFloat = 320

    static func clampedSize(_ fitting: NSSize) -> NSSize {
        NSSize(
            width: min(max(fitting.width, minWidth), maxWidth),
            height: max(fitting.height, minHeight)
        )
    }
}

/// HUD 视图模型：订阅 Pipeline 与 AudioCapture，汇总为显示属性
@MainActor
final class RecordingHUDViewModel: ObservableObject {
    @Published private(set) var phase: VoicePipelineState = .idle
    @Published private(set) var levelHistory = LevelHistory()
    @Published private(set) var targetAppName = ""
    @Published private(set) var report: InjectionReport?
    /// 音频侧提示（上限/设备回落/采集中断），下次录音时清除
    @Published private(set) var banner: String?

    private var cancellables = Set<AnyCancellable>()

    init(pipeline: VoicePipeline, audioCapture: AudioCapture) {
        pipeline.$state.sink { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                // 终止态后紧跟的 idle：锁存终止态展示（面板停留由 Controller 计时，
                // 展示内容不能随 idle 立即清空）；下一次录音自然解除锁存
                if case .idle = state, self.phase.isTerminalFeedback { return }
                if case .recording = state {
                    // 新一次录音：重置波形与提示
                    self.levelHistory.reset()
                    self.banner = nil
                }
                self.phase = state
            }
        }.store(in: &cancellables)

        pipeline.$targetSnapshot.sink { [weak self] target in
            MainActor.assumeIsolated { self?.targetAppName = target?.appName ?? "" }
        }.store(in: &cancellables)

        pipeline.$lastInjectionReport.sink { [weak self] report in
            MainActor.assumeIsolated { self?.report = report }
        }.store(in: &cancellables)

        // levels 从音频线程发布（Phase 3 约定），切主线程消费
        audioCapture.levels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] db in
                MainActor.assumeIsolated { self?.levelHistory.push(decibels: db) }
            }
            .store(in: &cancellables)

        audioCapture.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                MainActor.assumeIsolated { self?.banner = Self.bannerText(for: event) }
            }
            .store(in: &cancellables)
    }

    /// 阶段/反馈文案
    var statusText: String {
        switch phase {
        case .idle:
            return ""
        case .recording:
            return "正在录音"
        case .transcribing:
            return "转写中…"
        case .refining:
            return "润色中…"
        case .injecting:
            return "注入中…"
        case .injected:
            return feedback == .manualPaste ? "已复制，Cmd+V 手动粘贴" : "已注入"
        case .failed(let reason):
            return "失败：\(reason)"
        case .cancelled:
            return "已取消"
        }
    }

    var feedback: HUDFeedback {
        if case .injected = phase {
            return report?.outcome == .clipboardOnly ? .manualPaste : .success
        }
        if case .failed = phase {
            return .failure
        }
        return .none
    }

    /// "未润色"角标：润色回退/旁路后注入原文时显示（§3.4.1）
    var showsUnrefinedBadge: Bool {
        if case .injected = phase {
            return report?.wasRefined == false
        }
        return false
    }

    /// 音频事件 → 提示文案（纯函数，nonisolated 便于任意上下文调用与单测）
    nonisolated static func bannerText(for event: AudioCaptureEvent) -> String {
        switch event {
        case .maxDurationReached:
            return "已达最长录音时长"
        case .inputDeviceFellBackToDefault:
            return "指定麦克风已断开，已切换系统默认"
        case .captureInterrupted:
            return "采集中断，已保留已录部分"
        }
    }
}

/// HUD 内容视图
struct RecordingHUDView: View {
    @ObservedObject var model: RecordingHUDViewModel

    var body: some View {
        HStack(spacing: 10) {
            leadingIndicator
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.statusText)
                        .font(.callout.weight(.medium))
                        // 长文案（如失败原因指引）换行展示，不截断
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.showsUnrefinedBadge {
                        Text("未润色")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                subtitle
            }
            // 文案列宽上限；超出部分换行（面板尺寸由 Controller 随内容调整）
            .frame(maxWidth: HUDLayout.textColumnMaxWidth, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        switch model.feedback {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
        case .manualPaste:
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(.orange)
                .font(.title3)
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.title3)
        case .none:
            if case .recording = model.phase {
                waveform
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    /// 实时波形（FR-A2）：最近电平渲染为竖条
    private var waveform: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(model.levelHistory.bars.enumerated()), id: \.offset) { _, bar in
                RoundedRectangle(cornerRadius: 1)
                    .frame(width: 3, height: 3 + 17 * CGFloat(bar))
                    .foregroundStyle(.red)
            }
        }
        .frame(width: 84, height: 20)
    }

    @ViewBuilder
    private var subtitle: some View {
        if let banner = model.banner {
            Text(banner)
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } else if !model.targetAppName.isEmpty, case .recording = model.phase {
            // §3.4.3：录音中显示当前注入目标（Phase 7 实装真实快照）
            Text("注入目标：\(model.targetAppName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// HUD 面板控制器：非激活 NSPanel 托管 + 显示/隐藏调度
@MainActor
final class RecordingHUDController {
    private let viewModel: RecordingHUDViewModel
    private let clock: any PipelineClock
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    /// 内容尺寸变化订阅（KVO preferredContentSize → 面板随内容调整，长文案不截断）
    private var sizeObserver: AnyCancellable?

    init(
        pipeline: VoicePipeline,
        audioCapture: AudioCapture,
        clock: any PipelineClock = SystemPipelineClock()
    ) {
        self.viewModel = RecordingHUDViewModel(pipeline: pipeline, audioCapture: audioCapture)
        self.clock = clock

        pipeline.$state.sink { [weak self] state in
            MainActor.assumeIsolated {
                self?.stateDidChange(state, report: pipeline.lastInjectionReport)
            }
        }.store(in: &cancellables)
    }

    private func stateDidChange(_ state: VoicePipelineState, report: InjectionReport?) {
        if let delay = HUDVisibility.hideDelay(for: state, report: report) {
            // 状态机终止态后紧跟着回 idle：已安排停留时不被该 idle 打断
            if case .idle = state, hideTask != nil { return }
            scheduleHide(after: delay)
        } else {
            hideTask?.cancel()
            hideTask = nil
            show()
        }
    }

    // MARK: - 面板生命周期

    private func show() {
        let panel = ensurePanel()
        // 尺寸随内容（长文案换行后撑高），再定位（保持底部居中）
        if let hosting = panel.contentViewController as? NSHostingController<RecordingHUDView> {
            applyContentSize(hosting.preferredContentSize)
        }
        positionBottomCenter(panel)
        panel.alphaValue = 1
        // 非激活面板：不 makeKey、不 activate，焦点留在目标 App；
        // 用 orderFrontRegardless——LSUIElement App 未激活时 orderFront 可能不生效（真机实测坑）
        panel.orderFrontRegardless()
        AppLog.debug(.hud, "HUD 显示")
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await clock.sleep(for: delay)
            } catch {
                return // 被新状态打断
            }
            hide()
            hideTask = nil
        }
    }

    private func hide() {
        guard let panel else { return }
        AppLog.debug(.hud, "HUD 隐藏")
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let panel = self?.panel else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        })
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let hostingController = NSHostingController(rootView: RecordingHUDView(model: viewModel))
        // 内容尺寸变化（长文案换行撑高等）→ 自动重算 preferredContentSize，KVO 订阅后调整面板
        hostingController.sizingOptions = .preferredContentSize
        sizeObserver = hostingController.publisher(for: \.preferredContentSize)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in
                Task { @MainActor in self?.applyContentSize(size) }
            }
        let panel = NSPanel(contentViewController: hostingController)
        // 不抢焦点（硬要求）：点击不激活、不接受键鼠、不在 Exposé 中干扰
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        // 本 App 失活（切到其他 App）时不被系统隐藏——菜单栏 App 录音时焦点必然在别的 App
        panel.hidesOnDeactivate = false
        // 全屏终端与多 Space 可见（§3.4.3）
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.panel = panel
        return panel
    }

    /// 位置：主屏可见区域底部居中（避开 Dock；VoiceInk 惯例，简单可靠）
    private func positionBottomCenter(_ panel: NSPanel) {
        // LSUIElement App 无键盘焦点窗口时 NSScreen.main 可能为 nil，回退首块屏
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = panel.frame.size
        let origin = NSPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.minY + 28
        )
        panel.setFrameOrigin(origin)
    }

    /// 内容尺寸 → 面板尺寸（钳制上下限；长文案换行后撑高，保持底部锚点居中）
    private func applyContentSize(_ size: NSSize) {
        guard let panel else { return }
        let clamped = HUDLayout.clampedSize(size)
        let current = panel.contentView?.frame.size ?? .zero
        // 防 KVO → resize → 布局 → KVO 回环：尺寸未变（容差内）不重设
        guard abs(clamped.width - current.width) > 0.5 || abs(clamped.height - current.height) > 0.5 else { return }
        panel.setContentSize(clamped)
        positionBottomCenter(panel)
    }
}
