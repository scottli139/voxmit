import Combine
import Foundation

/// 模型下载状态机（需求文档 §4.2.3 模型下载策略）
enum ModelDownloadState: Sendable, Equatable {
    case notStarted            // 未下载/未就绪
    case downloading(Double)   // 进度 0...1
    case ready                 // 落盘校验通过，可加载
    case failed(String)        // 用户可读原因，可重试

    /// 是否就绪（引擎切换决策用）
    var isReady: Bool { self == .ready }
}

/// 模型下载通道（网络/磁盘交互隔离；单测 mock，禁止真实网络）
protocol ModelDownloading: Sendable {
    /// 已下载模型的目录（不存在或不完整返回 nil）
    func existingModelFolder() -> URL?
    /// 执行下载并返回模型目录；progress 回调 0...1；实现需支持断点续传
    func download(progress: @Sendable @escaping (Double) -> Void) async throws -> URL
    /// 删除不完整模型目录（自愈重下前置；失败不阻塞调用方）
    func removeInvalidModel()
}

/// 模型下载管理器（@MainActor；状态经 @Published 供设置页与引擎路由订阅）
@MainActor
final class ModelDownloadManager: ObservableObject {
    @Published private(set) var state: ModelDownloadState

    private let downloader: any ModelDownloading
    private var downloadTask: Task<Void, Never>?
    /// 会话级自愈闸：激活失败后的自动重试只进行一次，防"激活失败↔重试"循环
    private var autoRetryUsed = false

    init(downloader: any ModelDownloading) {
        self.downloader = downloader
        // 落盘校验：已存在完整模型目录则直接就绪
        self.state = downloader.existingModelFolder() != nil ? .ready : .notStarted
    }

    /// 就绪时模型的目录（引擎激活用）；未就绪为 nil
    var modelFolder: URL? {
        state.isReady ? downloader.existingModelFolder() : nil
    }

    /// 幂等启动下载：已就绪或下载中为 no-op；失败后再次调用即重试
    func startDownloadIfNeeded() {
        guard state != .ready, downloadTask == nil else { return }
        state = .downloading(0)
        AppLog.info(.download, "模型下载任务启动")
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let folder = try await downloader.download { [weak self] fraction in
                    Task { @MainActor in
                        self?.state = .downloading(min(max(fraction, 0), 1))
                    }
                }
                // 落盘校验：返回目录真实存在才置 ready（模型可加载性由引擎激活时兜底）
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
                if exists && isDirectory.boolValue {
                    state = .ready
                    AppLog.info(.download, "模型就绪")
                } else {
                    state = .failed("模型文件校验失败")
                    AppLog.error(.download, "模型落盘校验失败：\(folder.path)")
                }
            } catch {
                state = .failed(error.localizedDescription)
                AppLog.error(.download, "模型下载失败：\(error.localizedDescription)")
            }
            downloadTask = nil
        }
    }

    /// 重估就绪状态（模型规格等设置变更后调用）；下载进行中不打断
    func reevaluate() {
        guard downloadTask == nil else { return }
        state = downloader.existingModelFolder() != nil ? .ready : .notStarted
    }

    /// 模型激活/加载失败时自愈：删除不完整产物目录（强制干净重下）→ 打回失败态
    /// （设置页可重试、不再误显示"已就绪"）→ 每会话自动重试下载一次（防循环：
    /// 自动重试后再失败则停在 failed 态等手动重试）。
    /// 幂等；下载进行中不打断。failed 态 resolve 落 speech，不会再次激活，无死循环。
    func markInvalidModel(reason: String) {
        guard downloadTask == nil else { return }
        downloader.removeInvalidModel()
        state = .failed(reason)
        if !autoRetryUsed {
            autoRetryUsed = true
            AppLog.notice(.download, "模型不完整（\(reason)），本会话自动重试下载一次")
            startDownloadIfNeeded()
        } else {
            AppLog.error(.download, "自动重试已用尽，保持失败态待手动重试：\(reason)")
        }
    }
}
