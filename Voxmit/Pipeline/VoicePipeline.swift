import Foundation

/// 主链路状态机协调器（需求文档 §4.2.0 / §3.4.1）
///
/// Phase 0 只提供状态承载与菜单栏展示所需的派生属性。
/// 状态迁移逻辑（按下 ≥200ms 进入录音、录音 <300ms 误触取消、Esc 取消、
/// 5 分钟上限、旁路修饰键判定）在 Phase 2 与 HotkeyManager 一并实现，
/// 按键时序判定集中在这一层，不散落到各模块。
@MainActor
final class VoicePipeline: ObservableObject {

    /// 当前主链路状态；迁移只允许由协调器内部发起
    @Published private(set) var state: VoicePipelineState = .idle

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
