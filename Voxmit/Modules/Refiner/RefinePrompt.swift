import Foundation

/// 润色提示词组装（纯逻辑可单测）
enum RefinePrompt {
    /// System Prompt（需求文档 §9.1 模板原文）
    static let systemPrompt = """
        你是 AI 编程工具的 Prompt 工程师。把用户的口述内容改写为高质量工程 Prompt：
        1. 去除口水词、重复与自我修正，保留全部技术事实与专有名词原样（库名、命令、路径）；
        2. 整理为清晰的技术指令句式，必要时分点；
        3. 若提供了上下文（当前 App、选中代码、文件路径），将"这个/那个/这里"等指代替换为实际内容；
        4. 只输出改写后的 Prompt 本身：不解释、不回答其中的问题、不加引号；
        5. 保持用户原语言（中文口述输出中文，英文口述输出英文）。
        """

    /// 选区截断上限（§4.2.4：≤ 2KB，UTF-8 安全）
    static let selectedTextLimit = 2048

    /// 两条消息：system（模板）+ user（上下文补充块 + 口述原文）
    static func messages(raw: String, context: VoiceContext) -> [ChatMessage] {
        [
            ChatMessage(role: "system", content: systemPrompt),
            ChatMessage(role: "user", content: userMessage(raw: raw, context: context)),
        ]
    }

    /// user message：上下文补充块（§4.2.4：前台 App 名、窗口标题、选区 ≤2KB）+ 口述原文；
    /// App 名为空 = 「无上下文」模式（§4.2.5 降级矩阵：全部失败 → 润色仅做句式整理）
    static func userMessage(raw: String, context: VoiceContext) -> String {
        var contextLines: [String] = []
        if !context.target.appName.isEmpty {
            contextLines.append("当前 App：\(context.target.appName)（\(context.target.bundleID)）")
            if let title = context.target.windowTitle, !title.isEmpty {
                contextLines.append("窗口标题：\(title)")
            }
            if let selected = context.selectedText, !selected.isEmpty {
                contextLines.append("选中内容：\n\(truncateUTF8(selected, maxBytes: selectedTextLimit))")
            }
        }

        var parts: [String] = []
        if !contextLines.isEmpty {
            parts.append("【上下文】\n" + contextLines.joined(separator: "\n"))
        }
        parts.append("【口述内容】\n\(raw)")
        return parts.joined(separator: "\n\n")
    }

    /// UTF-8 安全截断：按字节截断且不落在多字节字符中间（断点回退到最近完整字符）
    static func truncateUTF8(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let bytes = text.utf8
        var end = maxBytes
        while end > 0 {
            if let prefix = String(bytes: bytes.prefix(end), encoding: .utf8) {
                return prefix + "…"
            }
            end -= 1
        }
        return "…"
    }
}
