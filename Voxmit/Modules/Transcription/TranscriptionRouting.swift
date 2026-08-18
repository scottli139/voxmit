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

    /// 切换引擎（主线程）
    func use(_ engine: any TranscriptionEngine) {
        dispatchPrecondition(condition: .onQueue(.main))
        objectWillChange.send()
        lock.withLock { _current = engine }
    }

    func transcribe(samples: [Float]) async throws -> String {
        try await current.transcribe(samples: samples)
    }
}
