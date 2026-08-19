import Foundation

/// 超时哨兵（预算竞速用）
private struct RefineTimeoutError: Error {}

/// Prompt 润色（FR-D1，需求文档 §4.2.4）：OpenAI 兼容端点；
/// 任何异常（超时/失败/未配 Key/用户拒绝）一律回退原文并标记 refined=false，不阻断主链路。
final class PromptRefiner: PromptRefining, @unchecked Sendable {
    /// 润色设置快照（调用时读取，用户改设置即时生效）
    struct Settings: Sendable, Equatable {
        var baseURL: String
        var model: String
        var enabled: Bool
    }

    /// 时序预算（2026-08-19 放宽，需求文档 §4.2.4）：首次尝试 2.0s + 退避 0.3s + 重试 2.0s = 4.3s
    /// （原因：Moonshot 响应波动 + 冷连接 TLS 握手，3s 预算下超时回退率过高；"润色成功但略慢"优于"快但未润色"）
    static let firstAttemptTimeout: TimeInterval = 2.0
    static let retryBackoff: TimeInterval = 0.3
    static let retryAttemptTimeout: TimeInterval = 2.0

    /// 请求体约束（§4.2.4：输出 < 500 tokens）
    static let maxTokens = 500

    private let client: any ChatCompleting
    private let settingsProvider: @Sendable () -> Settings
    private let apiKeyProvider: @Sendable () -> String?
    /// 隐私门（§4.2.4「首次启用润色时弹一次说明」）：挡在首次实际发送前；
    /// 返回 true 放行（并记 acknowledged），false 本次跳过（下次再问）
    private let privacyGate: @Sendable () async -> Bool
    private let clock: any PipelineClock

    init(
        client: any ChatCompleting,
        settingsProvider: @escaping @Sendable () -> Settings,
        apiKeyProvider: @escaping @Sendable () -> String?,
        privacyGate: @escaping @Sendable () async -> Bool,
        clock: any PipelineClock = SystemPipelineClock()
    ) {
        self.client = client
        self.settingsProvider = settingsProvider
        self.apiKeyProvider = apiKeyProvider
        self.privacyGate = privacyGate
        self.clock = clock
    }

    func refine(raw: String, context: VoiceContext) async -> (text: String, refined: Bool) {
        guard !raw.isEmpty else { return (raw, false) }

        let settings = settingsProvider()
        guard settings.enabled else {
            AppLog.info(.refiner, "润色已全局关闭（llm.refineEnabled=false），直出原文")
            return (raw, false)
        }
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            AppLog.info(.refiner, "未配置 LLM API Key，直出原文（§4.2.4）")
            return (raw, false)
        }

        // 隐私门：首次实际发送前必挡一次
        guard await privacyGate() else {
            AppLog.notice(.refiner, "用户本次跳过润色（隐私确认），直出原文")
            return (raw, false)
        }

        let request = ChatCompletionRequest(
            model: settings.model,
            messages: RefinePrompt.messages(raw: raw, context: context),
            maxTokens: Self.maxTokens
        )
        let startedAt = Date()

        // 首次尝试（≤2.0s）
        if let text = await attempt(request, timeout: Self.firstAttemptTimeout, attemptNumber: 1) {
            return finish(text: text, startedAt: startedAt, model: settings.model, inputCount: raw.count)
        }

        // 退避 0.3s（可取消；取消时回退原文，由 Pipeline 的 checkCancellation 走 cancelled）
        do {
            try await clock.sleep(for: Self.retryBackoff)
        } catch {
            return (raw, false)
        }

        // 重试一次（≤2.0s）
        if let text = await attempt(request, timeout: Self.retryAttemptTimeout, attemptNumber: 2) {
            return finish(text: text, startedAt: startedAt, model: settings.model, inputCount: raw.count)
        }

        AppLog.notice(.refiner, "润色失败/超时，回退原文注入")
        return (raw, false)
    }

    // MARK: - 内部

    private func finish(text: String, startedAt: Date, model: String, inputCount: Int) -> (text: String, refined: Bool) {
        let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
        // 只记元数据（字数/耗时/模型），不记文本本体（隐私红线）
        AppLog.info(.refiner, "润色完成：耗时 \(milliseconds)ms，模型 \(model)，\(inputCount) 字 → \(text.count) 字")
        return (text, true)
    }

    private func attempt(_ request: ChatCompletionRequest, timeout: TimeInterval, attemptNumber: Int) async -> String? {
        let attemptStartedAt = Date()
        do {
            return try await withTimeout(seconds: timeout) {
                try await self.client.complete(request)
            }
        } catch {
            let milliseconds = Int(Date().timeIntervalSince(attemptStartedAt) * 1000)
            var detail = "第 \(attemptNumber) 次，\(Self.logCategory(of: error))，\(milliseconds)ms"
            if case let LLMClientError.httpStatus(_, snippet) = error, !snippet.isEmpty {
                detail += "，响应：\(snippet)"
            }
            AppLog.error(.refiner, "润色请求失败（\(detail)）")
            return nil
        }
    }

    /// 预算竞速：请求与虚拟时钟赛跑，先到者胜；超时哨兵触发则取消请求
    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await self.clock.sleep(for: seconds)
                throw RefineTimeoutError()
            }
            guard let result = try await group.next() else {
                throw RefineTimeoutError()
            }
            group.cancelAll()
            return result
        }
    }

    /// 日志分类（只落类别，不落 Key/文本本体；URLError 记 code 便于区分断网/DNS/连接拒绝）
    private static func logCategory(of error: Error) -> String {
        if error is RefineTimeoutError { return "timeout" }
        if let clientError = error as? LLMClientError { return clientError.logCategory }
        if error is CancellationError { return "cancelled" }
        if let urlError = error as? URLError { return "network-\(urlError.code.rawValue)" }
        return "network"
    }
}
