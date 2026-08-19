import Foundation
@testable import Voxmit

/// 注入测试用共享事件日志（记录系统服务调用顺序）。
/// 单一注入流程内方法按序调用，事件顺序即调用顺序。
final class InjectEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.withLock { events.append(event) }
    }

    var snapshot: [String] {
        lock.withLock { events }
    }

    func contains(_ event: String) -> Bool {
        lock.withLock { events.contains(event) }
    }
}

/// 剪贴板系统 mock（PasteboardManaging）
final class MockPasteboard: PasteboardManaging, @unchecked Sendable {
    private let lock = NSLock()
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
        get { lock.withLock { _captureReturn } }
        set { lock.withLock { _captureReturn = newValue } }
    }
    var writeReturn: Int? {
        get { lock.withLock { _writeReturn } }
        set { lock.withLock { _writeReturn = newValue } }
    }
    var restoreReturn: Bool {
        get { lock.withLock { _restoreReturn } }
        set { lock.withLock { _restoreReturn = newValue } }
    }
    var captureCallCount: Int { lock.withLock { _captureCallCount } }
    var writeCallCount: Int { lock.withLock { _writeCallCount } }
    var restoreCallCount: Int { lock.withLock { _restoreCallCount } }
    var receivedText: String? { lock.withLock { _receivedText } }
    var receivedExpectedChangeCount: Int? { lock.withLock { _receivedExpectedChangeCount } }

    func capture() async -> Int {
        eventLog?.append("capture")
        lock.withLock { _captureCallCount += 1 }
        return lock.withLock { _captureReturn }
    }

    func write(text: String) async -> Int? {
        eventLog?.append("write")
        lock.withLock {
            _writeCallCount += 1
            _receivedText = text
        }
        return lock.withLock { _writeReturn }
    }

    func restore(ifChangeCountEquals expected: Int) async -> Bool {
        eventLog?.append("restore")
        lock.withLock {
            _restoreCallCount += 1
            _receivedExpectedChangeCount = expected
        }
        return lock.withLock { _restoreReturn }
    }
}

/// 模拟按键系统 mock（KeyEventPosting）
final class MockKeyEventPoster: KeyEventPosting, @unchecked Sendable {
    private let lock = NSLock()
    private let eventLog: InjectEventLog?
    private var _postPasteCallCount = 0
    private var _postReturnCallCount = 0

    init(eventLog: InjectEventLog? = nil) {
        self.eventLog = eventLog
    }

    var postPasteCallCount: Int { lock.withLock { _postPasteCallCount } }
    var postReturnCallCount: Int { lock.withLock { _postReturnCallCount } }

    func postPaste() async {
        eventLog?.append("postPaste")
        lock.withLock { _postPasteCallCount += 1 }
    }

    func postReturn() async {
        eventLog?.append("postReturn")
        lock.withLock { _postReturnCallCount += 1 }
    }
}
