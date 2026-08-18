import Foundation
@testable import Voxmit

/// 模型下载 mock：不触网、不落盘；进度/成败/目录可控（docs/TESTING.md：禁真实网络下载）
final class MockModelDownloader: ModelDownloading, @unchecked Sendable {
    /// 控制"已存在完整模型目录"判定（init 就绪/reevaluate 路径）
    var existingFolder: URL?
    var progressSteps: [Double] = [0.2, 0.6, 1.0]
    var downloadError: (any Error)?
    /// 返回给管理器的目录（默认 /tmp 真实存在，过落盘校验；可改为不存在路径制造校验失败）
    var returnedFolder = URL(fileURLWithPath: "/tmp")
    /// 下载挂起时长（配合 delayClock 虚拟时间），用于"下载中"状态断言
    var delay: TimeInterval?
    var delayClock: MockClock?

    private(set) var downloadCallCount = 0
    private(set) var reportedProgress: [Double] = []
    private(set) var removeInvalidModelCallCount = 0

    func existingModelFolder() -> URL? { existingFolder }

    func removeInvalidModel() {
        removeInvalidModelCallCount += 1
        existingFolder = nil // 模拟删除：目录不再存在
    }

    func download(progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        downloadCallCount += 1
        if let delay, let delayClock {
            try await delayClock.sleep(for: delay)
        }
        for step in progressSteps {
            progress(step)
            reportedProgress.append(step)
        }
        if let downloadError { throw downloadError }
        return returnedFolder
    }
}
