# Voxmit

macOS 菜单栏常驻的语音驱动 AI 编程工具：按住全局热键说话 → 本地语音转写 → LLM 润色为工程 Prompt → 自动注入当前 AI 开发工具（Kimi Code / Claude Code / Cursor 等）的输入框。

> 当前阶段：**需求与方案设计已完成，MVP 开发启动中**。仓库当前以文档为主。

## 文档地图

| 文件 | 内容 |
|---|---|
| [需求分析与方案说明](语音编程工具-需求分析与方案说明.md) | 需求与方案唯一事实来源（FR 编号、优先级、里程碑、接口契约） |
| [PLAN.md](PLAN.md) | 开发计划与任务进度（唯一的任务看板） |
| [AGENTS.md](AGENTS.md) | 面向 AI 编程代理的项目指南（文档体系、约定、权限与隐私红线） |
| [CONTRIBUTING.md](CONTRIBUTING.md) | 贡献指南：环境搭建、提交前检查链、Commit/PR 规范 |
| [docs/TESTING.md](docs/TESTING.md) | 测试要求：质量门禁、单测规范、真机手动测试矩阵 |
| [docs/implementation-notes.md](docs/implementation-notes.md) | 实现细节知识库：踩坑、架构要点、发布流程 |

## 开发环境

- macOS 14+，Xcode 16+（Swift 6 工具链）
- 目标平台：macOS 14 Sonoma 及以上，优先 Apple Silicon
- 技术栈：Swift 6 + SwiftUI/AppKit · WhisperKit 本地转写 · OpenAI 兼容 LLM 润色

参与开发详见 [CONTRIBUTING.md](CONTRIBUTING.md)。
