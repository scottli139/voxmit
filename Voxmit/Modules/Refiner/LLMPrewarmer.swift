import Foundation

/// LLM 连接预热（2026-08-19）：录音开始时以 fire-and-forget 发一个轻量请求
/// （GET {baseURL}/models），让共享 URLSession 的 keep-alive 连接池提前完成 TLS 握手，
/// 避免冷连接占用润色预算（真机：首试 1219ms 超当时 1.2s 预算、重试 1562ms 超 1.5s 回退）。
///
/// 必须与 Refiner 共享同一 URLSession 实例，否则连接池不共享、预热无效
/// （VoxmitAppDelegate 中同一个 llmSession 注入两侧）。失败静默（DEBUG 级）；
/// 不打响应体、不落 API Key；进行中不重复发。
final class LLMPrewarmer: @unchecked Sendable {
    /// 预热请求超时（轻量探测，不阻塞主链路）
    static let timeout: TimeInterval = 2.0

    /// 请求执行点（默认共享 URLSession；单测注入 mock，禁真实网络）
    typealias RequestExecutor = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let baseURLProvider: @Sendable () -> String
    private let apiKeyProvider: @Sendable () -> String?
    private let enabledProvider: @Sendable () -> Bool
    private let execute: RequestExecutor

    private let lock = NSLock()
    private var inFlight = false

    init(
        baseURLProvider: @escaping @Sendable () -> String,
        apiKeyProvider: @escaping @Sendable () -> String?,
        enabledProvider: @escaping @Sendable () -> Bool,
        execute: @escaping RequestExecutor
    ) {
        self.baseURLProvider = baseURLProvider
        self.apiKeyProvider = apiKeyProvider
        self.enabledProvider = enabledProvider
        self.execute = execute
    }

    /// 共享 URLSession 的生产执行点
    static func makeExecutor(session: URLSession) -> RequestExecutor {
        { request in
            try await session.data(for: request)
        }
    }

    /// fire-and-forget 预热；内部自带设置检查（润色开关 / API Key）与在飞防重
    func prewarm() {
        guard enabledProvider() else { return }
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else { return }
        // 原子 check-and-set：已有预热在飞则不重复发
        let shouldStart = lock.withLock { () -> Bool in
            if inFlight { return false }
            inFlight = true
            return true
        }
        guard shouldStart else { return }

        guard let url = URL(string: baseURLProvider() + "/models") else {
            lock.withLock { inFlight = false }
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeout
        // /models 需要鉴权；Key 只在请求头里，不进日志、不打响应体
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let startedAt = Date()
        Task { [execute] in
            defer {
                self.lock.withLock { inFlight = false }
            }
            do {
                let (_, response) = try await execute(request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                AppLog.debug(.refiner, "LLM 连接预热完成（HTTP \(status)，\(milliseconds)ms）")
            } catch {
                // 失败静默：预热是优化项，不影响主链路
                AppLog.debug(.refiner, "LLM 连接预热失败（静默）：\(error.localizedDescription)")
            }
        }
    }
}
