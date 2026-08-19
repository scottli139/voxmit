import Foundation

/// chat/completions 消息
struct ChatMessage: Sendable, Equatable {
    let role: String      // "system" / "user"
    let content: String
}

/// OpenAI 兼容 chat/completions 请求（纯值类型可单测组装）
///
/// 不含 temperature：实测 Kimi Code 端点（kimi-for-coding 系列）只允许 temperature=1，
/// 传其他值直接 400；省略时各服务商走各自默认值（Moonshot 默认 0.3），兼容性最好（2026-08-19 踩坑）。
struct ChatCompletionRequest: Sendable, Equatable {
    let model: String
    let messages: [ChatMessage]
    let maxTokens: Int
}

enum LLMClientError: LocalizedError, Equatable {
    case missingAPIKey
    /// bodySnippet：错误响应体摘录（≤500 字符）。OpenAI 兼容错误体为 {"error":{...}} 元信息，
    /// 是 4xx/5xx 排障的关键依据；请求体永不落日志
    case httpStatus(Int, bodySnippet: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "未配置 LLM API Key"
        case .httpStatus(let code, let snippet):
            return snippet.isEmpty ? "LLM 服务返回 HTTP \(code)" : "LLM 服务返回 HTTP \(code)：\(snippet)"
        case .invalidResponse: return "LLM 响应解析失败"
        }
    }

    /// 日志分类文案（只落类别，不落 Key/文本本体）
    var logCategory: String {
        switch self {
        case .missingAPIKey: return "missing-api-key"
        case .httpStatus(let code, _): return "http-\(code)"
        case .invalidResponse: return "invalid-response"
        }
    }
}

/// LLM 请求通道（网络隔离；单测 mock，禁真实网络）
protocol ChatCompleting: Sendable {
    /// 返回 assistant 文本；非 2xx / 解析失败 / 未配 Key 抛 LLMClientError
    func complete(_ request: ChatCompletionRequest) async throws -> String
}

/// OpenAI 兼容 chat/completions 客户端（§4.2.4；默认 Kimi/Moonshot 端点，可配）。
/// Bearer Key 经 apiKeyProvider 从 Keychain 读取（日志禁止落 Key 与转写/润色文本本体）。
struct OpenAIChatClient: ChatCompleting {
    private let baseURLProvider: @Sendable () -> String
    private let apiKeyProvider: @Sendable () -> String?
    private let session: URLSession

    init(
        baseURLProvider: @escaping @Sendable () -> String,
        apiKeyProvider: @escaping @Sendable () -> String?,
        session: URLSession = .shared
    ) {
        self.baseURLProvider = baseURLProvider
        self.apiKeyProvider = apiKeyProvider
        self.session = session
    }

    func complete(_ request: ChatCompletionRequest) async throws -> String {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            throw LLMClientError.missingAPIKey
        }
        let endpoint = URL(string: baseURLProvider() + "/chat/completions")!
        let urlRequest = try Self.makeRequest(endpoint: endpoint, apiKey: apiKey, request: request)
        // 请求元数据（端点/模型/消息数）落 debug；请求体与 Key 永不落日志
        AppLog.debug(.refiner, "LLM 请求：POST \(endpoint.absoluteString)，模型 \(request.model)，消息 \(request.messages.count) 条")
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMClientError.httpStatus(http.statusCode, bodySnippet: Self.bodySnippet(data))
        }
        return try Self.parseContent(data)
    }

    /// 错误响应体摘录（默认 ≤500 字符）：4xx/5xx 的服务端错误信息是排障关键
    static func bodySnippet(_ data: Data, limit: Int = 500) -> String {
        String((String(data: data, encoding: .utf8) ?? "").prefix(limit))
    }

    /// 组装 URLRequest（纯逻辑可单测）：POST + JSON 头 + Bearer + 请求体
    static func makeRequest(
        endpoint: URL, apiKey: String, request: ChatCompletionRequest
    ) throws -> URLRequest {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": request.model,
            "messages": request.messages.map { ["role": $0.role, "content": $0.content] },
            "max_tokens": request.maxTokens,
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    /// 解析 choices[0].message.content（纯逻辑可单测）
    static func parseContent(_ data: Data) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String
                }
                let message: Message
            }
            let choices: [Choice]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let content = response.choices.first?.message.content,
              !content.isEmpty
        else {
            throw LLMClientError.invalidResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
