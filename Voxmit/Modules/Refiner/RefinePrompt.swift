import Foundation

/// 润色提示词组装（纯逻辑可单测）
enum RefinePrompt {
    /// System Prompt（需求文档 §9.1 模板原文；防脑补硬约束：忠于原意、指代不补全、短句不换词不扩展）
    static let systemPrompt = """
        你是 AI 编程工具的 Prompt 工程师。把用户的口述内容改写为高质量文本：
        1. 去除口水词、重复与自我修正，保留全部技术事实与专有名词原样（库名、命令、路径）；
        2. 严格忠于原意：输出必须与口述表达同一件事，只允许通顺化、去口水词与句式整理；禁止新增、删除或改变任何动作、对象、目标、步骤——口述里没有的东西一律不得出现；禁止把口述里的泛化动词替换成更具体的动词（如把"做/弄"改成"执行/生成/优化"）；
        3. 上下文（当前 App、窗口标题、选中代码）只用于理解口述中的指代（"这个/那个/这里/它"），绝不能被当作要操作、修改、优化、打开、关闭的对象；
        4. 若口述是工程任务，整理为清晰的技术指令句式，必要时分点；若与工程无关，只做通顺化，绝不强行改写为指令或补充操作对象；
        5. 短促的对话/流程/应允用语（如"可以了""提交吧""好的""收到""两个都做吧""都做吧"）按字面通顺化：绝不替换其中的动词、绝不补全"这个/那个/两个/它"等指代所指的对象、绝不引入原文没有的名词（如"命令/任务/操作"）；这类短句脱离上下文可能不自洽，宁可原样保留也不得自行补全；
        6. 只输出改写后的文本本身：不解释、不回答其中的问题、不加引号；
        7. 保持用户原语言（中文口述输出中文，英文口述输出英文）。
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
            // 终端类窗口标题噪声大（进程名/TMPDIR/尺寸等），指代价值低且会诱导 LLM 脑补
            // （真机：口述"可以了，提交吧"被结合 Terminal 标题脑补成"提高 Terminal 窗口显示效果"），
            // 故对 terminal 目标省略窗口标题，只保留 App 名与分类语义。
            if context.appCategory != .terminal,
               let title = context.target.windowTitle, !title.isEmpty {
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
