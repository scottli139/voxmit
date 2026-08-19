import Foundation

/// URLSession 前台下载通道（RepoHTTPClient 实装）：
/// data task + DataDelegate 流式写 <dest>.partial → 完成校验 → 原子移动。
/// 不依赖 HEAD 元数据（大小从 GET 响应推导；镜像小文件无 Content-Length 属正常，跳过大小校验）。
final class URLSessionRepoHTTPClient: NSObject, RepoHTTPClient, @unchecked Sendable {
    /// delegate=self 与存储属性初始化顺序冲突，init 内两段式赋值（先 super.init 再建 session）
    private var session: URLSession!
    private let lock = NSLock()
    private var handlers: [Int: FileDownloadHandler] = [:]

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30 // 连接/读写级超时（资源级默认 7 天，大文件无碍）
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func getJSON(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if Task.isCancelled { throw CancellationError() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RepoDownloadError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1, url.absoluteString)
        }
        return data
    }

    func downloadFile(
        _ url: URL,
        to destination: URL,
        resumeFrom: Int64,
        progress: @Sendable @escaping (Int64) -> Void
    ) async throws -> Int64? {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var request = URLRequest(url: url)
        if resumeFrom > 0 {
            request.setValue("bytes=\(resumeFrom)-", forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int64?, Error>) in
                let handler = FileDownloadHandler(
                    destination: destination,
                    resumeFrom: resumeFrom,
                    progress: progress,
                    continuation: continuation
                )
                lock.withLock { handlers[task.taskIdentifier] = handler }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - 任务状态（全部在 lock 内访问）

    private func handler(for task: URLSessionTask) -> FileDownloadHandler? {
        lock.withLock { handlers[task.taskIdentifier] }
    }

    private func removeHandler(for task: URLSessionTask) -> FileDownloadHandler? {
        lock.withLock { handlers.removeValue(forKey: task.taskIdentifier) }
    }
}

/// 单文件下载状态（仅在 client 锁内访问）
private final class FileDownloadHandler {
    let destination: URL
    let partialURL: URL
    let resumeFrom: Int64
    let progress: @Sendable (Int64) -> Void
    private let continuation: CheckedContinuation<Int64?, Error>

    var handle: FileHandle?
    /// 预期总大小（含续传起点；响应未知大小时为 nil——镜像小文件属正常，跳过大小校验）
    var expectedTotal: Int64?
    var downloaded: Int64
    private var resumed = false

    init(destination: URL, resumeFrom: Int64, progress: @escaping @Sendable (Int64) -> Void,
         continuation: CheckedContinuation<Int64?, Error>) {
        self.destination = destination
        self.partialURL = destination.appendingPathExtension("partial")
        self.resumeFrom = resumeFrom
        self.progress = progress
        self.continuation = continuation
        self.downloaded = resumeFrom
    }

    func openHandle() throws {
        if !FileManager.default.fileExists(atPath: partialURL.path) {
            FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: partialURL)
    }

    /// 服务器忽略 Range 从头返回（200）：截断 partial 重写
    func truncateForFreshDownload() throws {
        try handle?.truncate(atOffset: 0)
        downloaded = 0
    }

    func write(_ data: Data) throws {
        try handle?.write(contentsOf: data)
        downloaded += Int64(data.count)
        progress(downloaded)
    }

    func succeed() {
        guard !resumed else { return }
        resumed = true
        try? handle?.close()
        continuation.resume(returning: expectedTotal)
    }

    func fail(_ error: Error) {
        guard !resumed else { return }
        resumed = true
        try? handle?.close()
        continuation.resume(throwing: error)
    }
}

// MARK: - URLSessionDataDelegate（委托回调在 URLSession 后台队列；handler 状态仅由其任务顺序访问）

extension URLSessionRepoHTTPClient: URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse
    ) async -> URLSession.ResponseDisposition {
        guard let handler = handler(for: dataTask) else { return .cancel }
        do {
            guard let http = response as? HTTPURLResponse else {
                handler.fail(RepoDownloadError.httpStatus(-1, handler.destination.lastPathComponent))
                return .cancel
            }
            switch http.statusCode {
            case 200:
                // 服务器忽略 Range 从头返回：partial 截断重写
                if handler.resumeFrom > 0 {
                    try handler.truncateForFreshDownload()
                }
                if response.expectedContentLength >= 0 {
                    handler.expectedTotal = handler.downloaded + response.expectedContentLength
                }
                try handler.openHandle()
            case 206:
                // 续传：响应大小为剩余字节，预期总大小 = 续传起点 + 剩余
                if response.expectedContentLength >= 0 {
                    handler.expectedTotal = handler.downloaded + response.expectedContentLength
                }
                try handler.openHandle()
            case 416:
                // Range 不可满足（partial 损坏/超尺寸）：删除 partial，编排器重试时从头下载
                try? FileManager.default.removeItem(at: handler.partialURL)
                handler.fail(RepoDownloadError.httpStatus(416, handler.destination.lastPathComponent))
                return .cancel
            default:
                handler.fail(RepoDownloadError.httpStatus(http.statusCode, handler.destination.lastPathComponent))
                return .cancel
            }
            return .allow
        } catch {
            handler.fail(error)
            return .cancel
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handler = handler(for: dataTask) else { return }
        do {
            try handler.write(data)
        } catch {
            handler.fail(error)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let handler = removeHandler(for: task) else { return }
        if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                handler.fail(CancellationError())
            } else {
                handler.fail(error)
            }
            return
        }
        // 完成：大小校验（仅响应已知大小时；镜像小文件无 Content-Length 则跳过）→ 原子移动
        if let expected = handler.expectedTotal, handler.downloaded != expected {
            handler.fail(RepoDownloadError.incompleteFile(
                expected: expected, actual: handler.downloaded, path: handler.destination.lastPathComponent
            ))
            return
        }
        do {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: handler.destination.path) {
                try fileManager.removeItem(at: handler.destination)
            }
            try fileManager.moveItem(at: handler.partialURL, to: handler.destination)
            handler.succeed()
        } catch {
            handler.fail(error)
        }
    }
}
