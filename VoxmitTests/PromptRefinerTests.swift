import Foundation
import Testing
@testable import Voxmit

/// LLM 请求通道 mock（禁真实网络）
private final class MockChatCompleting: ChatCompleting, @unchecked Sendable {
    enum Behavior {
        case success(String)
        case failure(any Error)
        /// 睡到指定时长后按 then 结束（配 MockClock，用于超时竞速）
        indirect case sleep(TimeInterval, then: Behavior)
    }

    var behaviors: [Behavior] = [Behavior.success("默认润色结果")]
    var clock: MockClock?

    private(set) var requests: [ChatCompletionRequest] = []
    private var index = 0

    func complete(_ request: ChatCompletionRequest) async throws -> String {
        requests.append(request)
        let behavior = behaviors[min(index, behaviors.count - 1)]
        index += 1
        return try await run(behavior)
    }

    private func run(_ behavior: Behavior) async throws -> String {
        switch behavior {
        case .success(let text):
            return text
        case .failure(let error):
            throw error
        case .sleep(let duration, let then):
            guard let clock else { fatalError("sleep 行为需要注入 MockClock") }
            try await clock.sleep(for: duration)
            return try await run(then)
        }
    }
}

/// 上下文样例
private func makeContext(selectedText: String? = nil) -> VoiceContext {
    VoiceContext(
        target: TargetSnapshot(
            pid: 1234, bundleID: "com.apple.Terminal", appName: "Terminal",
            windowTitle: "voxmit — zsh", capturedAt: Date(timeIntervalSince1970: 0)
        ),
        appCategory: .terminal,
        selectedText: selectedText,
        cliSession: nil
    )
}

struct PromptRefinerTests {

    @Test func budgetConstants_v010Allocation() {
        // v0.10 预算分配：3.5 + 0.3 + 3.5 = 7.3s
        // （冷连接握手 2.6s 内首试完成并入池、热连接重试 2.9s < 3.5s 兜底）
        #expect(PromptRefiner.firstAttemptTimeout == 3.5)
        #expect(PromptRefiner.retryBackoff == 0.3)
        #expect(PromptRefiner.retryAttemptTimeout == 3.5)
        #expect(PromptRefiner.firstAttemptTimeout
            + PromptRefiner.retryBackoff
            + PromptRefiner.retryAttemptTimeout == 7.3)
    }

    private func makeRefiner(
        client: MockChatCompleting,
        clock: MockClock,
        settings: PromptRefiner.Settings = .init(baseURL: "https://api.test/v1", model: "test-model", enabled: true),
        apiKey: String? = "test-key",
        privacyAccepted: Bool = true,
        gateCounter: GateCallCounter? = nil
    ) -> PromptRefiner {
        client.clock = clock
        return PromptRefiner(
            client: client,
            settingsProvider: { settings },
            apiKeyProvider: { apiKey },
            privacyGate: {
                gateCounter?.increment()
                return privacyAccepted
            },
            clock: clock
        )
    }

    private func settle() async {
        for _ in 0..<12 { await Task { @MainActor in }.value }
    }

    // MARK: - 直出矩阵（不发请求）

    @Test func refine_noAPIKey_returnsRawNoRequest() async {
        let client = MockChatCompleting()
        let refiner = makeRefiner(client: client, clock: MockClock(), apiKey: nil)

        let result = await refiner.refine(raw: "帮我重构这个函数", context: makeContext())

        #expect(result.text == "帮我重构这个函数")
        #expect(result.refined == false)
        #expect(client.requests.isEmpty)
    }

    @Test func refine_disabled_returnsRawNoRequest() async {
        let client = MockChatCompleting()
        let refiner = makeRefiner(
            client: client, clock: MockClock(),
            settings: .init(baseURL: "https://api.test/v1", model: "m", enabled: false)
        )

        let result = await refiner.refine(raw: "原文", context: makeContext())

        #expect(result == ("原文", false))
        #expect(client.requests.isEmpty)
    }

    @Test func refine_privacyDenied_returnsRawNoRequest() async {
        let client = MockChatCompleting()
        let counter = GateCallCounter()
        let refiner = makeRefiner(
            client: client, clock: MockClock(),
            privacyAccepted: false, gateCounter: counter
        )

        let result = await refiner.refine(raw: "原文", context: makeContext())

        #expect(result == ("原文", false))
        #expect(client.requests.isEmpty)
        #expect(counter.count == 1) // 门被调用且只在发送前
    }

    @Test func refine_noKeyOrDisabled_privacyGateNotCalled() async {
        let client = MockChatCompleting()
        let counter = GateCallCounter()
        let refiner = makeRefiner(
            client: client, clock: MockClock(), apiKey: nil, gateCounter: counter
        )

        _ = await refiner.refine(raw: "原文", context: makeContext())

        #expect(counter.count == 0) // 未走到发送就不惊动隐私门
    }

    // MARK: - 成功与重试

    @Test func refine_success_returnsRefinedWithContext() async {
        let client = MockChatCompleting()
        client.behaviors = [.success("润色后的工程 Prompt")]
        let refiner = makeRefiner(client: client, clock: MockClock())

        let result = await refiner.refine(raw: "这个函数为什么报错", context: makeContext())

        #expect(result == ("润色后的工程 Prompt", true))
        #expect(client.requests.count == 1)
        // user message 组装：上下文（App 名/窗口标题）+ 口述原文
        let user = client.requests[0].messages[1].content
        #expect(user.contains("当前 App：Terminal（com.apple.Terminal）"))
        #expect(user.contains("窗口标题：voxmit — zsh"))
        #expect(user.contains("这个函数为什么报错"))
    }

    @Test func refine_firstAttemptFails_retriesOnceAfterBackoff() async throws {
        let client = MockChatCompleting()
        client.behaviors = [
            .failure(LLMClientError.httpStatus(500, bodySnippet: "")),
            .success("重试成功"),
        ]
        let clock = MockClock()
        let refiner = makeRefiner(client: client, clock: clock)

        let task = Task { await refiner.refine(raw: "原文", context: makeContext()) }
        // 推进到退避挂起点后放行 300ms
        for _ in 0..<12 { await Task { @MainActor in }.value }
        clock.advance(by: PromptRefiner.retryBackoff)
        let result = await task.value

        #expect(result == ("重试成功", true))
        #expect(client.requests.count == 2) // 恰好重试 1 次
    }

    @Test func refine_bothAttemptsFail_fallbackRaw() async throws {
        let client = MockChatCompleting()
        client.behaviors = [
            .failure(LLMClientError.httpStatus(500, bodySnippet: "")),
            .failure(LLMClientError.invalidResponse),
        ]
        let clock = MockClock()
        let refiner = makeRefiner(client: client, clock: clock)

        let task = Task { await refiner.refine(raw: "原文", context: makeContext()) }
        for _ in 0..<12 { await Task { @MainActor in }.value }
        clock.advance(by: PromptRefiner.retryBackoff)
        let result = await task.value

        #expect(result == ("原文", false))
        #expect(client.requests.count == 2) // 只重试一次，不无限重试
    }

    // MARK: - 超时（预算竞速，假时钟）

    @Test func refine_timeout_fallbackWithinBudget() async throws {
        let client = MockChatCompleting()
        // 两次尝试都睡到远超预算
        client.behaviors = [
            .sleep(60, then: .success("不该到达")),
            .sleep(60, then: .success("不该到达")),
        ]
        let clock = MockClock()
        let refiner = makeRefiner(client: client, clock: clock)

        let task = Task { await refiner.refine(raw: "原文", context: makeContext()) }
        for _ in 0..<12 { await Task { @MainActor in }.value }
        // 首次预算到点（3.5s）→ 退避（0.3s）→ 重试预算到点（3.5s）
        clock.advance(by: PromptRefiner.firstAttemptTimeout)
        for _ in 0..<12 { await Task { @MainActor in }.value }
        clock.advance(by: PromptRefiner.retryBackoff)
        for _ in 0..<12 { await Task { @MainActor in }.value }
        clock.advance(by: PromptRefiner.retryAttemptTimeout)
        let result = await task.value

        #expect(result == ("原文", false))
        #expect(client.requests.count == 2) // 预算内恰好两次尝试
    }

    // MARK: - 截断与请求体

    @Test func refine_selectedTextOver2KB_truncatedUTF8Safe() async {
        let client = MockChatCompleting()
        let refiner = makeRefiner(client: client, clock: MockClock())
        // 3000 字节：多字节中文字符跨 2KB 边界
        let selected = String(repeating: "汉", count: 800) // 2400B（3B/字）
        let context = makeContext(selectedText: selected)

        _ = await refiner.refine(raw: "优化这段代码", context: context)

        let user = client.requests[0].messages[1].content
        // 取出"选中内容"段落（截断体 ≤2KB + 省略号，UTF-8 不断裂）
        let beforeSpeech = user.components(separatedBy: "【口述内容】").first ?? ""
        let selectedPart = beforeSpeech.components(separatedBy: "选中内容：\n").last ?? ""
        #expect(!selectedPart.contains("�"))
        #expect(selectedPart.utf8.count <= RefinePrompt.selectedTextLimit + 3) // 截断 + 省略号
    }

    @Test func refine_requestBody_fieldsCorrect() async {
        let client = MockChatCompleting()
        let refiner = makeRefiner(client: client, clock: MockClock())

        _ = await refiner.refine(raw: "原文", context: makeContext())

        let request = client.requests[0]
        #expect(request.model == "test-model")
        #expect(request.maxTokens == 500)
        #expect(request.messages.count == 2)
        #expect(request.messages[0].role == "system")
        #expect(request.messages[0].content.contains("Prompt 工程师"))
        #expect(request.messages[1].role == "user")
    }

    // MARK: - UTF-8 截断纯函数

    @Test func truncateUTF8_underLimit_unchanged() {
        let text = String(repeating: "汉", count: 10) // 30B
        #expect(RefinePrompt.truncateUTF8(text, maxBytes: 2048) == text)
    }

    @Test func truncateUTF8_multibyteBoundary_noBrokenChar() {
        // 683 个"汉" = 2049B，2048 截断点落在字符中间
        let text = String(repeating: "汉", count: 683)
        let truncated = RefinePrompt.truncateUTF8(text, maxBytes: 2048)
        #expect(!truncated.contains("�"))
        #expect(truncated.utf8.count <= 2048 + 3) // 截断体 + 省略号
    }

    @Test func truncateUTF8_exactBoundary_clean() {
        // 10 个"汉"（30B）+ "abc"（3B）= 33B；截 33B 恰在边界
        let truncated = RefinePrompt.truncateUTF8(String(repeating: "汉", count: 10) + "abc", maxBytes: 33)
        #expect(truncated.contains("abc"))
    }
}

/// 隐私门调用计数（@Sendable 闭包内可变访问，测试内串行）
private final class GateCallCounter: @unchecked Sendable {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// LLM 连接预热（共享 session 语义 + 在飞防重 + 失败静默）
struct LLMPrewarmerTests {

    private final class ExecutorRecorder: @unchecked Sendable {
        private(set) var requests: [URLRequest] = []
        var error: (any Error)?
        var delay: TimeInterval?
        var clock: MockClock?

        func makeExecutor() -> LLMPrewarmer.RequestExecutor {
            { request in
                self.requests.append(request)
                if let delay = self.delay, let clock = self.clock {
                    try await clock.sleep(for: delay)
                }
                if let error = self.error { throw error }
                return (Data(), HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!)
            }
        }
    }

    private func makePrewarmer(
        recorder: ExecutorRecorder,
        apiKey: String? = "k",
        enabled: Bool = true
    ) -> LLMPrewarmer {
        LLMPrewarmer(
            baseURLProvider: { "https://api.test/v1" },
            apiKeyProvider: { apiKey },
            enabledProvider: { enabled },
            execute: recorder.makeExecutor()
        )
    }

    private func settle() async {
        for _ in 0..<12 { await Task { @MainActor in }.value }
    }

    @Test func prewarm_sendsModelsRequestWithAuthHeader() async {
        let recorder = ExecutorRecorder()
        let prewarmer = makePrewarmer(recorder: recorder)

        prewarmer.prewarm()
        await settle()

        #expect(recorder.requests.count == 1)
        #expect(recorder.requests[0].url?.absoluteString == "https://api.test/v1/models")
        #expect(recorder.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(recorder.requests[0].timeoutInterval == LLMPrewarmer.timeout)
    }

    @Test func prewarm_timeoutConstantCoversTlsHandshake() {
        // 实测 TLS 握手 2.3~2.7s：预热超时必须大于握手时间（曾取 2s 致预热永远失败形同虚设）
        #expect(LLMPrewarmer.timeout == 8.0)
        #expect(LLMPrewarmer.timeout > 2.7)
    }

    @Test func prewarm_disabledOrNoKey_skipsRequest() async {
        let recorder = ExecutorRecorder()

        makePrewarmer(recorder: recorder, enabled: false).prewarm()
        makePrewarmer(recorder: recorder, apiKey: nil).prewarm()
        makePrewarmer(recorder: recorder, apiKey: "").prewarm()
        await settle()

        #expect(recorder.requests.isEmpty)
    }

    @Test func prewarm_inFlight_noDuplicate() async throws {
        let recorder = ExecutorRecorder()
        let clock = MockClock()
        recorder.delay = 60 // 挂起 60 虚拟秒，制造"在飞"窗口
        recorder.clock = clock
        let prewarmer = makePrewarmer(recorder: recorder)

        prewarmer.prewarm()
        await settle()
        prewarmer.prewarm() // 在飞中：不重复发
        await settle()
        #expect(recorder.requests.count == 1)

        clock.advance(by: 60) // 放行完成
        await settle()
        prewarmer.prewarm() // 完成后可再次预热（连接可能已被服务端关闭）
        await settle()
        #expect(recorder.requests.count == 2)
    }

    @Test func prewarm_failure_silentAndRetriable() async {
        let recorder = ExecutorRecorder()
        recorder.error = NSError(domain: "mock", code: -1001)
        let prewarmer = makePrewarmer(recorder: recorder)

        prewarmer.prewarm() // 失败静默（不抛错）
        await settle()
        #expect(recorder.requests.count == 1)

        recorder.error = nil
        prewarmer.prewarm() // 在飞标记已复位，可再试
        await settle()
        #expect(recorder.requests.count == 2)
    }
}

/// Pipeline 预热触发时机（录音开始 fire-and-forget；权限拒绝不预热）
@MainActor
struct PipelinePrewarmTriggerTests {

    private func settle() async {
        for _ in 0..<12 { await Task { @MainActor in }.value }
    }

    @Test func hotkeyDown_recordingStarted_prewarmsOnce() async throws {
        let counter = PrewarmCounter()
        let clock = MockClock()
        let pipeline = VoicePipeline(
            clock: clock,
            audio: MockAudioCapture(),
            transcription: MockTranscriptionEngine(),
            refiner: MockRefiner(),
            injector: MockInjector(),
            contextCollector: MockContextCollector(),
            autoSend: { false },
            prewarmLLM: { counter.increment() }
        )
        pipeline.applyPermissionSnapshot(PermissionSnapshot(
            microphone: .authorized, listenEventGranted: true, accessibilityGranted: true
        ))

        pipeline.handleHotkeyDown(bypassModifierActive: false)
        #expect(counter.count == 1) // 录音开始即预热（fire-and-forget）

        clock.advance(by: VoicePipeline.confirmationDelay)
        await settle()
        #expect(pipeline.isRecording)
        #expect(counter.count == 1) // 确认期通过不重复触发

        pipeline.handleHotkeyUp()
        await settle()
        #expect(counter.count == 1) // 松手不再触发
    }

    @Test func hotkeyDown_micDenied_noPrewarm() {
        let counter = PrewarmCounter()
        let pipeline = VoicePipeline(
            clock: MockClock(),
            audio: MockAudioCapture(),
            transcription: MockTranscriptionEngine(),
            refiner: MockRefiner(),
            injector: MockInjector(),
            contextCollector: MockContextCollector(),
            autoSend: { false },
            prewarmLLM: { counter.increment() }
        )
        pipeline.applyPermissionSnapshot(PermissionSnapshot(
            microphone: .denied, listenEventGranted: true, accessibilityGranted: true
        ))

        pipeline.handleHotkeyDown(bypassModifierActive: false)

        #expect(counter.count == 0) // 麦克风拒绝早退，不预热
    }

    @Test func menuToggle_alsoPrewarms() async throws {
        let counter = PrewarmCounter()
        let clock = MockClock()
        let pipeline = VoicePipeline(
            clock: clock,
            audio: MockAudioCapture(),
            transcription: MockTranscriptionEngine(),
            refiner: MockRefiner(),
            injector: MockInjector(),
            contextCollector: MockContextCollector(),
            autoSend: { false },
            prewarmLLM: { counter.increment() }
        )
        pipeline.applyPermissionSnapshot(PermissionSnapshot(
            microphone: .authorized, listenEventGranted: true, accessibilityGranted: true
        ))

        pipeline.handleMenuToggle() // 菜单降级路径同样预热
        #expect(counter.count == 1)

        clock.advance(by: VoicePipeline.confirmationDelay)
        await settle()
        #expect(pipeline.isRecording)
    }
}

/// 预热计数（@Sendable 闭包内可变访问）
private final class PrewarmCounter: @unchecked Sendable {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// LLM 客户端静态组装/解析（纯逻辑）
struct LLMClientTests {

    @Test func makeRequest_methodHeadersAndBody() throws {
        let request = ChatCompletionRequest(
            model: "moonshot-v1-8k",
            messages: [ChatMessage(role: "system", content: "sys"), ChatMessage(role: "user", content: "hi")],
            maxTokens: 500
        )
        let urlRequest = try OpenAIChatClient.makeRequest(
            endpoint: URL(string: "https://api.moonshot.cn/v1/chat/completions")!,
            apiKey: "secret-key",
            request: request
        )

        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")

        let body = try JSONSerialization.jsonObject(with: urlRequest.httpBody!) as? [String: Any]
        #expect(body?["model"] as? String == "moonshot-v1-8k")
        #expect(body?["max_tokens"] as? Int == 500)
        // 请求体不携带 temperature（Kimi Code 端点仅允许 temperature=1，省略走服务商默认，见 LLMClient 注释）
        #expect(body?["temperature"] == nil)
        let messages = body?["messages"] as? [[String: String]]
        #expect(messages?.count == 2)
        #expect(messages?[0]["role"] == "system")
        #expect(messages?[1]["content"] == "hi")
    }

    @Test func parseContent_validResponse_returnsText() throws {
        let data = Data(#"{"choices":[{"message":{"content":"  改写结果  "}}]}"#.utf8)
        #expect(try OpenAIChatClient.parseContent(data) == "改写结果")
    }

    @Test func parseContent_invalidJSON_throwsInvalidResponse() {
        #expect(throws: LLMClientError.invalidResponse) {
            _ = try OpenAIChatClient.parseContent(Data("not json".utf8))
        }
    }

    @Test func parseContent_emptyChoices_throwsInvalidResponse() {
        #expect(throws: LLMClientError.invalidResponse) {
            _ = try OpenAIChatClient.parseContent(Data(#"{"choices":[]}"#.utf8))
        }
    }
}
