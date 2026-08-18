import Foundation
@testable import Voxmit

/// 虚拟时钟：手动推进时间；sleep 以 continuation 挂起，advance 越过截止点时唤醒；
/// 任务被取消时立即以 CancellationError 唤醒（与 SystemPipelineClock 语义一致）。
/// 注意：协议的非隔离异步方法（如 transcribe）在协作线程池执行，sleep/advance/onCancel
/// 会被多线程并发调用——内部状态必须用锁保护（@unchecked 因此成立）。
final class MockClock: PipelineClock, @unchecked Sendable {
    private struct Sleeper {
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    // 注意：Date 内部以 2001 纪元存储秒数（大基数，Double 误差 ~1e-7），
    // 涉及时长边界的用例需用 ±1ms 逼近来断言，不能依赖"恰好等于阈值"
    private var _now = Date(timeIntervalSince1970: 0)
    private var sleepers: [UUID: Sleeper] = [:]

    var now: Date {
        lock.withLock { _now }
    }

    func sleep(for interval: TimeInterval) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // 取消检查与注册在同一把锁内完成，配合 onCancel 的 removeValue 保证单次 resume
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let deadline = _now.addingTimeInterval(interval)
                // 截止点已过（任务实际运行晚于 advance 的竞态）：立即完成，不挂起
                guard deadline > _now else {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                lock.unlock()
            }
        } onCancel: {
            let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// 推进虚拟时间，唤醒所有到期的 sleep（锁内收集并移除，锁外 resume）
    func advance(by interval: TimeInterval) {
        let due: [Sleeper] = lock.withLock {
            _now = _now.addingTimeInterval(interval)
            // 先收集到期 id 再删除（遍历中不得修改字典）
            let dueIDs = sleepers.filter { $0.value.deadline <= _now }.map(\.key)
            return dueIDs.compactMap { sleepers.removeValue(forKey: $0) }
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }
}

/// 音频采集 mock（AudioCapturing）
final class MockAudioCapture: AudioCapturing, @unchecked Sendable {
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var cancelCallCount = 0
    var samplesToReturn: [Float] = [0.01, 0.02, 0.03]
    var startError: (any Error)?

    func start() throws {
        startCallCount += 1
        if let startError { throw startError }
    }

    func stop() -> [Float] {
        stopCallCount += 1
        return samplesToReturn
    }

    func cancel() {
        cancelCallCount += 1
    }
}

/// 转写引擎 mock
final class MockTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    let name = "mock"
    var result = "帮我重构这个函数"
    var error: (any Error)?
    /// 配合 delayClock 使用：transcribe 内部先按虚拟时钟 sleep，用于"处理中 Esc 取消"场景
    var delay: TimeInterval?
    var delayClock: MockClock?

    private(set) var callCount = 0
    private(set) var receivedSamples: [Float]?

    func transcribe(samples: [Float]) async throws -> String {
        callCount += 1
        receivedSamples = samples
        if let delay, let delayClock {
            try await delayClock.sleep(for: delay)
        }
        if let error { throw error }
        return result
    }
}

/// 润色 mock
final class MockRefiner: PromptRefining, @unchecked Sendable {
    var refinedText = "润色后的工程 Prompt"

    private(set) var callCount = 0
    private(set) var receivedRaw: String?
    private(set) var receivedContext: VoiceContext?

    func refine(raw: String, context: VoiceContext) async -> (text: String, refined: Bool) {
        callCount += 1
        receivedRaw = raw
        receivedContext = context
        return (refinedText, true)
    }
}

/// 注入 mock
final class MockInjector: TextInjecting, @unchecked Sendable {
    var outcome: InjectionOutcome = .pasted

    private(set) var callCount = 0
    private(set) var receivedText: String?
    private(set) var receivedTarget: TargetSnapshot?
    private(set) var receivedAutoSend: Bool?

    func inject(text: String, into target: TargetSnapshot, autoSend: Bool) async -> InjectionOutcome {
        callCount += 1
        receivedText = text
        receivedTarget = target
        receivedAutoSend = autoSend
        return outcome
    }
}

/// 上下文采集 mock
final class MockContextCollector: ContextCollecting, @unchecked Sendable {
    var target = TargetSnapshot(
        pid: 1234,
        bundleID: "com.apple.Terminal",
        appName: "Terminal",
        windowTitle: nil,
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    private(set) var callCount = 0

    func snapshotTarget() -> TargetSnapshot {
        callCount += 1
        return target
    }
}
