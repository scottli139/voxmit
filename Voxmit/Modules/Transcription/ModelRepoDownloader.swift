import Foundation

// 自实现模型下载器（2026-08-18 决策反转：弃用 WhisperKit.download，根因见 implementation-notes——
// swift-transformers 依赖 HEAD 元数据，hf-mirror 的 resolve-cache 对小文件常缺 Content-Length 必挂；
// 本下载器不依赖 HEAD，大小取自 tree API 与 GET 响应）。
//
// 分层：清单解析/命名/进度聚合/续传决策 = 纯逻辑可单测；URLSession 通道 = 系统交互薄壳（真机验收）。

/// 仓库文件条目（tree API 中 type=="file" 的项）
struct ModelRepoFileEntry: Equatable, Sendable {
    let path: String   // 仓库内相对路径（如 openai_whisper-small/config.json）
    let size: Int64?   // tree API 的 size；镜像小文件可能缺失（nil）
}

/// 清单与命名规则（纯逻辑）
enum ModelRepoManifest {
    /// 模型仓库固定 ID
    static let modelRepoID = "argmaxinc/whisperkit-coreml"
    /// tokenizer 需在模型目录根的两个文件（离线激活的必要条件，真机验证）
    static let tokenizerFiles = ["tokenizer.json", "tokenizer_config.json"]

    /// 变体 → 模型目录名（openai_whisper-<variant>；沿用 asr.modelVariant 取值）
    static func variantDirectoryName(_ variant: String) -> String {
        "openai_whisper-\(variant)"
    }

    /// 变体 → tokenizer 仓库 ID（openai/whisper-<variant>）
    static func tokenizerRepoID(_ variant: String) -> String {
        "openai/whisper-\(variant)"
    }

    /// 清单 URL（HF tree API；官方与 hf-mirror 结构一致）
    static func manifestURL(endpoint: String, variant: String) -> URL? {
        URL(string: "\(endpoint)/api/models/\(modelRepoID)/tree/main/\(variantDirectoryName(variant))?recursive=true")
    }

    static func fileURL(endpoint: String, repoID: String, path: String) -> URL? {
        URL(string: "\(endpoint)/\(repoID)/resolve/main/\(path)")
    }

    /// tree API JSON → 文件条目（目录项跳过；解析失败抛 invalidManifest）
    static func parseFileEntries(_ data: Data) throws -> [ModelRepoFileEntry] {
        struct Entry: Decodable {
            let type: String
            let path: String
            let size: Int64?
        }
        do {
            return try JSONDecoder().decode([Entry].self, from: data)
                .filter { $0.type == "file" }
                .map { ModelRepoFileEntry(path: $0.path, size: $0.size) }
        } catch {
            throw RepoDownloadError.invalidManifest(error.localizedDescription)
        }
    }
}

enum RepoDownloadError: LocalizedError, Equatable {
    case httpStatus(Int, String)                          // 状态码 + 资源定位
    case incompleteFile(expected: Int64, actual: Int64, path: String)  // 完成后大小校验不符
    case invalidManifest(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code, let resource):
            return "HTTP \(code)：\(resource)"
        case .incompleteFile(let expected, let actual, let path):
            return "文件不完整：\(path)（期望 \(expected)B，实际 \(actual)B）"
        case .invalidManifest(let reason):
            return "模型清单解析失败：\(reason)"
        }
    }
}

/// 下载进度聚合（总字节随响应到达动态回填——镜像小文件可能无大小，完成时补齐）。
/// 线程安全（NSLock）：客户端进度回调发生在 URLSession 委托队列线程。
final class DownloadProgressTracker: @unchecked Sendable {
    private struct FileProgress {
        var expected: Int64?
        var downloaded: Int64
    }

    private let lock = NSLock()
    private var files: [String: FileProgress] = [:]

    /// 总预期字节（仅计已知大小的文件）
    var totalExpectedBytes: Int64 {
        lock.withLock { files.values.compactMap(\.expected).reduce(0, +) }
    }

    var downloadedBytes: Int64 {
        lock.withLock { files.values.map(\.downloaded).reduce(0, +) }
    }

    var fraction: Double {
        lock.withLock {
            let total = files.values.compactMap(\.expected).reduce(Int64(0), +)
            guard total > 0 else { return 0 }
            let downloaded = files.values.map(\.downloaded).reduce(Int64(0), +)
            return min(1, Double(downloaded) / Double(total))
        }
    }

    /// 注册文件；alreadyHave = .partial 续传起点已有字节
    func register(path: String, expected: Int64?, alreadyHave: Int64) {
        lock.withLock {
            files[path] = FileProgress(expected: expected, downloaded: alreadyHave)
        }
    }

    /// 响应到达/下载完成后回填真实大小
    func setExpected(path: String, _ expected: Int64) {
        lock.withLock { files[path]?.expected = expected }
    }

    /// 汇报该文件累计下载字节（含续传起点）
    func advance(path: String, to downloaded: Int64) {
        lock.withLock { files[path]?.downloaded = downloaded }
    }
}

/// 仓库 HTTP 通道（系统交互隔离；单测 mock，禁真实网络）
protocol RepoHTTPClient: Sendable {
    /// GET JSON（tree 清单）
    func getJSON(_ url: URL) async throws -> Data
    /// 下载文件到 destination（经 <destination>.partial 续传/校验/原子移动由实现负责）；
    /// resumeFrom > 0 时带 Range 续传；progress 汇报该文件累计字节（含续传起点）；
    /// 返回预期总大小（GET 响应推导；未知为 nil——镜像小文件常缺 Content-Length，属正常）
    func downloadFile(
        _ url: URL,
        to destination: URL,
        resumeFrom: Int64,
        progress: @Sendable @escaping (Int64) -> Void
    ) async throws -> Int64?
}

/// 模型仓库下载编排器：清单 → 逐文件下载（续传 + 重试）→ tokenizer → 完成
struct ModelRepoDownloader: Sendable {
    /// 单文件失败重试次数与退避（1s/3s）
    static let maxRetries = 2
    static let retryBackoffs: [TimeInterval] = [1, 3]

    /// 计划下载的文件
    private struct PlannedFile {
        let trackKey: String
        let sourceURL: URL
        let destination: URL
        let expected: Int64?
    }

    private let client: any RepoHTTPClient
    private let clock: any PipelineClock

    init(client: any RepoHTTPClient, clock: any PipelineClock = SystemPipelineClock()) {
        self.client = client
        self.clock = clock
    }

    /// 下载指定变体到 downloadBase；返回模型目录 URL（tokenizer 两文件在目录根）
    func download(
        variant: String,
        endpoint: String,
        downloadBase: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        let variantDirName = ModelRepoManifest.variantDirectoryName(variant)
        let repoPath = "models/\(ModelRepoManifest.modelRepoID)"
        let modelFolder = downloadBase.appending(path: "\(repoPath)/\(variantDirName)", directoryHint: .isDirectory)

        // 1. 清单（tree API；大小取自 size 字段，不依赖 HEAD）
        guard let manifestURL = ModelRepoManifest.manifestURL(endpoint: endpoint, variant: variant) else {
            throw RepoDownloadError.invalidManifest("清单 URL 构造失败：\(endpoint)")
        }
        AppLog.info(.download, "获取模型清单：\(variantDirName)（端点 \(endpoint)）")
        let entries = try ModelRepoManifest.parseFileEntries(try await client.getJSON(manifestURL))
        AppLog.info(.download, "清单含 \(entries.count) 个文件（\(variantDirName)，端点 \(endpoint)）")

        // 2. 下载计划：模型文件 + tokenizer 两文件（模型目录根，离线激活必要条件）
        var plan: [PlannedFile] = entries.compactMap { entry in
            guard let sourceURL = ModelRepoManifest.fileURL(
                endpoint: endpoint, repoID: ModelRepoManifest.modelRepoID, path: entry.path
            ) else { return nil }
            return PlannedFile(
                trackKey: entry.path,
                sourceURL: sourceURL,
                destination: downloadBase.appending(path: "\(repoPath)/\(entry.path)"),
                expected: entry.size
            )
        }
        for name in ModelRepoManifest.tokenizerFiles {
            guard let sourceURL = ModelRepoManifest.fileURL(
                endpoint: endpoint, repoID: ModelRepoManifest.tokenizerRepoID(variant), path: name
            ) else { continue }
            plan.append(PlannedFile(
                trackKey: "tokenizer/\(name)",
                sourceURL: sourceURL,
                destination: modelFolder.appending(path: name),
                expected: nil // 大小在完成时回填
            ))
        }

        // 3. 逐文件下载；已有完整文件跳过、完整 partial 直接移动、半截 partial 续传
        let tracker = DownloadProgressTracker()
        for item in plan {
            try Task.checkCancellation()
            try await downloadOne(item, tracker: tracker, progress: progress)
        }
        progress(1.0)
        AppLog.info(.download, "模型全部文件下载完成：\(variantDirName)（端点 \(endpoint)）")
        return modelFolder
    }

    private func downloadOne(
        _ item: PlannedFile,
        tracker: DownloadProgressTracker,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        let partial = item.destination.appendingPathExtension("partial")
        let fileManager = FileManager.default

        // 已有完整文件（上次会话下载完成）：跳过（原子移动落盘的文件即完整）
        if fileManager.fileExists(atPath: item.destination.path) {
            let size = (try? fileManager.attributesOfItem(atPath: item.destination.path)[.size] as? Int64) ?? nil
            tracker.register(path: item.trackKey, expected: item.expected ?? size, alreadyHave: size ?? 0)
            progress(tracker.fraction)
            return
        }

        let partialSize = (try? fileManager.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? nil ?? 0

        // 崩溃在移动前的完整 partial：直接原子移动，不走网络
        if let expected = item.expected, partialSize == expected, partialSize > 0 {
            tracker.register(path: item.trackKey, expected: expected, alreadyHave: partialSize)
            if fileManager.fileExists(atPath: item.destination.path) {
                try fileManager.removeItem(at: item.destination)
            }
            try fileManager.moveItem(at: partial, to: item.destination)
            progress(tracker.fraction)
            return
        }

        tracker.register(path: item.trackKey, expected: item.expected, alreadyHave: partialSize)
        progress(tracker.fraction)

        var attempt = 0
        while true {
            try Task.checkCancellation()
            // 每次重试重新读取 partial 尺寸（上一次尝试可能已写入部分）
            let resumeFrom = (try? fileManager.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? nil ?? 0
            do {
                let startedAt = Date()
                let expected = try await client.downloadFile(
                    item.sourceURL,
                    to: item.destination,
                    resumeFrom: resumeFrom
                ) { downloaded in
                    tracker.advance(path: item.trackKey, to: downloaded)
                    progress(tracker.fraction)
                }
                if let expected {
                    tracker.setExpected(path: item.trackKey, expected)
                }
                let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                let sizeDesc = expected.map { "\($0)B" } ?? "大小未知"
                AppLog.info(.download, "文件完成：\(item.destination.lastPathComponent)（\(sizeDesc)，耗时 \(milliseconds)ms）")
                return
            } catch is CancellationError {
                throw CancellationError() // 取消不重试、不回退
            } catch {
                attempt += 1
                if attempt > Self.maxRetries {
                    AppLog.error(.download, "文件下载失败（重试用尽）：\(item.destination.lastPathComponent)：\(error.localizedDescription)")
                    throw error
                }
                AppLog.notice(.download, "文件下载失败，\(Self.retryBackoffs[attempt - 1])s 后重试（第 \(attempt) 次）：\(item.destination.lastPathComponent)：\(error.localizedDescription)")
                try await clock.sleep(for: Self.retryBackoffs[attempt - 1])
            }
        }
    }
}
