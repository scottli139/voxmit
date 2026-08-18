import Foundation

// 核心协议与数据模型，照抄需求文档 §9.1 契约；
// 实现时可微调签名，但职责划分与降级语义不得改变。

/// 主链路状态（需求文档 §3.4.1）
enum VoicePipelineState: Sendable, Equatable {
    case idle
    case recording(startedAt: Date)
    case transcribing
    case refining
    case injecting
    case injected           // 成功反馈，短暂停留后回 idle
    case failed(String)     // 用户可读原因
    case cancelled
}

/// 注入目标分类（需求文档 §4.2.5；bundleID → 分类适配表在 Phase 7 落地）
enum AppCategory: Sendable {
    case terminal
    case editor
    case browser
    case other
}

/// 注入目标快照：热键按下瞬间采集（需求文档 §3.4.3）
struct TargetSnapshot: Sendable {
    let pid: pid_t
    let bundleID: String
    let appName: String
    let windowTitle: String?
    let capturedAt: Date
}

/// 结构化上下文（需求文档 §4.2.5）；P0 仅填 target 与 appCategory
struct VoiceContext: Sendable {
    var target: TargetSnapshot
    var appCategory: AppCategory
    var selectedText: String?     // P1，AX 选区，截断 ≤ 2KB
    var cliSession: String?       // P1，AI CLI 识别结果
}

/// 转写引擎抽象（WhisperKit / Speech / 云端可运行时切换，Phase 5 实现）
/// Sendable：实现会被 @MainActor 的 Pipeline 跨隔离域异步调用
protocol TranscriptionEngine: Sendable {
    var name: String { get }
    func transcribe(samples: [Float]) async throws -> String
    // P1：func streamingTranscribe(...) -> AsyncThrowingStream<String, Error>
}

/// Prompt 润色（Phase 6 实现）
protocol PromptRefining: Sendable {
    /// 超时/失败/未配置 Key 必须在内部回退；refined 标记供 HUD 角标
    func refine(raw: String, context: VoiceContext) async -> (text: String, refined: Bool)
}

/// 结果注入（Phase 8 实现）
protocol TextInjecting: Sendable {
    /// 实现内部处理逐级降级；返回值表示最终实际到达的档位
    func inject(text: String, into target: TargetSnapshot, autoSend: Bool) async -> InjectionOutcome
}

/// 注入结果档位
enum InjectionOutcome: Sendable {
    case pasted           // Cmd+V 成功
    case axWritten        // AX 写入成功（P1）
    case clipboardOnly    // 降级：仅剪贴板
    case failed(String)
}

/// 音频采集（Phase 3 实装 AVAudioEngine，需求文档 §4.2.2）
protocol AudioCapturing {
    /// 开始采集到内存缓冲（不落盘）；无输入设备/权限被拒等抛错
    func start() throws
    /// 停止采集，返回 16kHz 单声道 Float32 样本
    func stop() -> [Float]
    /// 放弃本次采集（Esc / 误触取消），丢弃缓冲
    func cancel()
}

/// 上下文采集（Phase 7 实装，需求文档 §4.2.5）
protocol ContextCollecting {
    /// 热键按下瞬间快照注入目标（§3.4.3）
    func snapshotTarget() -> TargetSnapshot
}
