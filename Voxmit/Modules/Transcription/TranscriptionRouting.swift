import Foundation

/// 引擎解析结果（本地两引擎；云端 ASR 为 P1，需求文档 FR-C3）
enum EngineResolution: Sendable, Equatable {
    case whisperKit
    case speech
}

/// 引擎切换决策（纯逻辑可单测；§4.2.3 引擎矩阵）：
/// - 显式 speech → Speech
/// - whisperkit（默认）→ 模型就绪用 WhisperKit，未就绪 Speech 兜底
/// - cloud 等未实现值 → 回落本地默认路径（云端 ASR 为 P1 未实现）
enum TranscriptionEngineResolver {
    static func resolve(setting: String, modelReady: Bool) -> EngineResolution {
        switch setting {
        case "speech":
            return .speech
        default:
            return modelReady ? .whisperKit : .speech
        }
    }
}

/// 转写引擎路由器（FR-C1 运行时切换）：Pipeline 持有的稳定引用，底层引擎可热切换。
/// 线程模型：`use()` 约定主线程调用（dispatchPrecondition 断言；Combine 通知在主线程），
/// `current`/`transcribe` 任意线程可读（NSLock 保护）——真实转写在引擎自身上下文执行。
final class TranscriptionEngineRouter: TranscriptionEngine, ObservableObject, @unchecked Sendable {
    private let lock = NSLock()
    private var _current: any TranscriptionEngine

    /// 当前生效引擎（任意线程可读；设置页经 ObservableObject 订阅切换通知）
    var current: any TranscriptionEngine {
        lock.withLock { _current }
    }

    init(current: any TranscriptionEngine) {
        _current = current
    }

    var name: String { current.name }

    /// 切换引擎（主线程）：总是替换引用（调用方可能换了同类型的新实例）；
    /// 仅名称变化时通知 UI 与打点（设置写入会触发重复切换，防刷屏）
    func use(_ engine: any TranscriptionEngine) {
        dispatchPrecondition(condition: .onQueue(.main))
        let previous = lock.withLock { _current }
        lock.withLock { _current = engine }
        guard previous.name != engine.name else { return }
        objectWillChange.send()
        AppLog.info(.transcription, "转写引擎切换：\(previous.name) → \(engine.name)")
    }

    func transcribe(samples: [Float]) async throws -> String {
        let startedAt = Date()
        do {
            let text = try await current.transcribe(samples: samples)
            let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
            // 只记元数据（字数/耗时/引擎），不记文本本体（隐私红线）
            AppLog.info(.transcription, "转写完成：\(text.count) 字，耗时 \(milliseconds)ms（引擎 \(self.current.name)）")
            return text
        } catch {
            AppLog.error(.transcription, "转写失败（引擎 \(self.current.name)）：\(error.localizedDescription)")
            throw error
        }
    }
}
