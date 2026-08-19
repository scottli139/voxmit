import AppKit
import Foundation

// 下游模块占位实现：Phase 2 状态机接线用，随对应 Phase 替换为真实实现。
// 命名统一 NoOp/Placeholder 前缀，避免被误当成可用功能。

/// 占位音频采集（Phase 3 实装）：不采集任何数据
struct NoOpAudioCapture: AudioCapturing {
    func start() throws {}
    func stop() -> [Float] { [] }
    func cancel() {}
}

/// 占位转写引擎（Phase 5 实装）：恒返回空串 → Pipeline 按"空音频"静默结束（§4.2.3）
struct PlaceholderTranscriptionEngine: TranscriptionEngine {
    let name = "placeholder"
    func transcribe(samples: [Float]) async throws -> String { "" }
}

/// 占位润色（Phase 6 实装）：原样返回并标记未润色
struct NoOpPromptRefiner: PromptRefining {
    func refine(raw: String, context: VoiceContext) async -> (text: String, refined: Bool) {
        (raw, false)
    }
}

/// 占位注入：Phase 8 已落地完整流程，见 ClipboardInjector；本占位仅作未接线/测试默认值。
struct PlaceholderClipboardInjector: TextInjecting {
    func inject(text: String, into target: TargetSnapshot, autoSend: Bool) async -> InjectionOutcome {
        // NSPasteboard 约定主线程访问
        return await MainActor.run {
            NSPasteboard.general.clearContents()
            let ok = NSPasteboard.general.setString(text, forType: .string)
            if ok {
                AppLog.info(.injection, "已写入剪贴板（clipboardOnly 档，\(text.count) 字）")
            } else {
                AppLog.error(.injection, "剪贴板写入失败")
            }
            return ok ? .clipboardOnly : .failed("剪贴板写入失败")
        }
    }
}

/// 占位上下文采集（Phase 7 实装）：返回空快照，等价"无上下文"模式（§4.2.5 降级矩阵）
struct PlaceholderContextCollector: ContextCollecting {
    func snapshotTarget() -> TargetSnapshot {
        TargetSnapshot(pid: 0, bundleID: "", appName: "", windowTitle: nil, capturedAt: Date())
    }
}
