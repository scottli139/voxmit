import Foundation

/// 注入适配纯逻辑（Phase 8 P0）：换行折叠决策与实现。
/// 终端类目标（AppCategory.terminal）默认把换行折叠为空格，防止终端 TUI
/// 把多行转写解释为多次提交（需求文档 §4.2.6）。
enum InjectionAdapter {
    /// 换行折叠决策：CLI 目标（terminal）默认折叠；设置开关关闭则不折叠；其余分类不折叠
    static func shouldCollapseNewlines(category: AppCategory, settingEnabled: Bool) -> Bool {
        settingEnabled && category == .terminal
    }

    /// 折叠换行为空格（\r\n、\n、\r 全部替换为单个空格；不压缩其他空白，忠实原文）
    static func collapseNewlines(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
