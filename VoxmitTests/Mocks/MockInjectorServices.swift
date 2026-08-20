import Foundation
@testable import Voxmit

/// 注入测试用共享事件日志（记录系统服务调用顺序）。
/// 单一注入流程内方法按序调用，事件顺序即调用顺序。
/// @MainActor：注入链测试全程主线程，事件日志读写均在主线程。
@MainActor
final class InjectEventLog {
    private var events: [String] = []

    func append(_ event: String) { events.append(event) }

    var snapshot: [String] { events }

    func contains(_ event: String) -> Bool { events.contains(event) }
}

/// 剪贴板系统 mock（PasteboardManaging；@MainActor 同步）
@MainActor
final class MockPasteboard: PasteboardManaging {
    private let eventLog: InjectEventLog?

    private var _captureReturn = 100
    private var _writeReturn: Int? = 101
    private var _restoreReturn = true
    private var _captureCallCount = 0
    private var _writeCallCount = 0
    private var _restoreCallCount = 0
    private var _receivedText: String?
    private var _receivedExpectedChangeCount: Int?

    init(eventLog: InjectEventLog? = nil) {
        self.eventLog = eventLog
    }

    var captureReturn: Int {
        get { _captureReturn }
        set { _captureReturn = newValue }
    }
    var writeReturn: Int? {
        get { _writeReturn }
        set { _writeReturn = newValue }
    }
    var restoreReturn: Bool {
        get { _restoreReturn }
        set { _restoreReturn = newValue }
    }
    var captureCallCount: Int { _captureCallCount }
    var writeCallCount: Int { _writeCallCount }
    var restoreCallCount: Int { _restoreCallCount }
    var receivedText: String? { _receivedText }
    var receivedExpectedChangeCount: Int? { _receivedExpectedChangeCount }

    func capture() -> Int {
        eventLog?.append("capture")
        _captureCallCount += 1
        return _captureReturn
    }

    func write(text: String) -> Int? {
        eventLog?.append("write")
        _writeCallCount += 1
        _receivedText = text
        return _writeReturn
    }

    func restore(ifChangeCountEquals expected: Int) -> Bool {
        eventLog?.append("restore")
        _restoreCallCount += 1
        _receivedExpectedChangeCount = expected
        return _restoreReturn
    }
}

/// 模拟按键系统 mock（KeyEventPosting；@MainActor 同步）
@MainActor
final class MockKeyEventPoster: KeyEventPosting {
    private let eventLog: InjectEventLog?
    private var _postPasteCallCount = 0
    private var _postReturnCallCount = 0

    init(eventLog: InjectEventLog? = nil) {
        self.eventLog = eventLog
    }

    var postPasteCallCount: Int { _postPasteCallCount }
    var postReturnCallCount: Int { _postReturnCallCount }

    func postPaste() {
        eventLog?.append("postPaste")
        _postPasteCallCount += 1
    }

    func postReturn() {
        eventLog?.append("postReturn")
        _postReturnCallCount += 1
    }
}

/// 注入延迟调度 mock（InjectorDelaying）：记录调度动作，测试手动 fire 触发。
@MainActor
final class MockInjectorDelayer: InjectorDelaying {
    private(set) var scheduled: [(delay: TimeInterval, action: @MainActor @Sendable () -> Void)] = []

    func schedule(after interval: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) {
        scheduled.append((interval, action))
    }

    /// 测试：按调度顺序执行所有已排队动作；fireAll 期间新 schedule 的动作留到下一次
    func fireAll() {
        let batch = scheduled
        scheduled.removeAll()
        for (_, action) in batch {
            action()
        }
    }
}
