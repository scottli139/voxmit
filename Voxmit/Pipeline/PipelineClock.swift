import Foundation

/// 时钟抽象：状态机时序判定（200ms 防误触 / 300ms 误触取消）的时间源。
/// 生产环境用 SystemPipelineClock；单测注入 MockClock 手动推进虚拟时间，
/// 零真实睡眠、零系统依赖（见 docs/TESTING.md）。
protocol PipelineClock: Sendable {
    var now: Date { get }
    /// 睡眠指定时长；所在 Task 被取消时必须抛 CancellationError
    func sleep(for interval: TimeInterval) async throws
}

/// 真实时钟
struct SystemPipelineClock: PipelineClock {
    var now: Date { Date() }

    func sleep(for interval: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(interval))
    }
}
