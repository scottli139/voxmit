# 参与贡献 Voxmit

**[English](CONTRIBUTING.md) | 简体中文**

感谢你有兴趣参与贡献！Voxmit 是一款 macOS 菜单栏常驻的语音驱动 AI 编程工具（Swift 6 + SwiftUI/AppKit）。欢迎各种形式的贡献——bug 报告、新功能、文档、测试、翻译。

> 🤖 **欢迎使用 AI 辅助贡献。** 本项目由 AI 辅助构建。仓库根目录的 `AGENTS.md` 是为 AI 助手准备好的上下文文件；任务看板是 `PLAN.md`；需求唯一事实来源是 `语音编程工具-需求分析与方案说明.md`。

## 环境搭建

前置条件：macOS 14+、Xcode 16+（Swift 6 工具链）。

```bash
git clone https://github.com/scottli139/voxmit.git
cd voxmit
open Voxmit.xcodeproj   # SPM 依赖（WhisperKit 等）由 Xcode 自动解析
```

真机调试需为本机开发构建逐项授予三项系统权限（麦克风 / 输入监控 / 辅助功能），权限矩阵与降级行为见需求文档 §4.4。

## 提交前检查

以下两条都要过——CI 会强制执行：

```bash
xcodebuild build -scheme Voxmit -destination 'platform=macOS'
xcodebuild test -scheme Voxmit -destination 'platform=macOS'
```

提示：

- 涉及系统权限的功能（热键 / 注入 / 上下文），单测一律走协议 mock，不得要求运行环境持有真实权限；
- 主链路（热键 → 录音 → 转写 → 润色 → 注入）相关改动，需在 PR 描述中记录 `docs/TESTING.md` 手动测试矩阵的已执行项；
- SwiftLint / SwiftFormat 配置已排期但尚未接线，风格暂按现有 Swift 惯例。

## Commit 规范

约定式前缀 + 简要描述（中英文均可，与现有提交记录保持一致）：

```
feat: 右 Option 按住说话与防误触判定
fix: 修复剪贴板恢复覆盖用户新复制内容
docs: 补充权限矩阵说明
test / chore / style / refactor: ...
```

- AI 协助的提交，commit message 末尾加模型 trailer（格式 `Model: <模型名>`，以当次实际使用的模型为准）；纯人工提交不加；
- 版本号提升与发布仅由维护者操作（`chore: bump version` + tag）。

## Pull Request 流程

1. 从 `main` 切分支，保持 diff 聚焦——一个 PR 只做一件事；
2. 需求相关改动在 PR 描述中标注对应 FR 编号（需求文档 §3.1）；
3. 确保 CI 全绿（编译 + 单测）；主链路改动附手动测试执行记录；
4. 小 PR 评审快；大型改动请先开 issue 讨论，排期以 `PLAN.md` 为准。

## 代码质量要求

- **协议隔离可测试**：各模块按需求文档 §9.1 的协议解耦；核心逻辑（状态机、润色、注入决策）必须能在无系统权限的环境中被单测覆盖；
- **不提前实现**：严格按 FR 优先级动工（P0 → P1 → P2），MVP 阶段不实现 P1/P2 功能；
- **密钥零容忍**：LLM API Key 只存 Keychain；代码、配置、日志中禁止出现，评审时一票否决；
- **隐私红线**：录音数据仅存内存不落盘；任何外发网络请求（润色 / 云端 ASR）必须有用户告知与开关；
- **语言约定**：代码标识符英文、注释跟随 Swift 社区惯例；文档、commit 描述使用简体中文；面向用户的文档按需双语；
- **文档同步**：用户可见行为变更同步 `docs/USER_GUIDE.md`；任务进度只更新 `PLAN.md`；实现踩坑记入 `docs/implementation-notes.md`；双语文档（`README` ↔ `README.zh-CN`、`docs/index` ↔ `docs/index.zh-CN`、`CONTRIBUTING` ↔ `CONTRIBUTING.zh-CN`）必须成对更新；修改以上任何约定时同步 `AGENTS.md`。文档中的图示禁用 ASCII 字符画，统一用 mermaid 代码块。

## 从哪里开始

- `PLAN.md` 的「下一步行动」——当前波次任务与依赖约束；
- 需求文档 §8 的开放问题已决策（2026-08-17）；未来出现的新开放问题，需要维护者决策的事项不要擅自拍板；
- 有疑问？开一个带 `question` 标签的 issue。
