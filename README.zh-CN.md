# Voxmit

macOS 上的语音优先 AI 编程输入。按住全局热键说话，语音在本地转写，经 LLM 润色为工程化 Prompt，再自动注入你当前 AI 开发工具（Kimi Code / Claude Code / Cursor 等）的输入框。

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Swift](https://img.shields.io/badge/Swift-6-orange.svg)
![Platform](https://img.shields.io/badge/macOS-14%2B-blue.svg)
![AI-Built](https://img.shields.io/badge/100%25%20AI-Built-purple.svg)

**[English](README.md) | 简体中文**

## 🌐 官网

访问项目网站：**[https://scottli139.github.io/voxmit](https://scottli139.github.io/voxmit)**

## 界面截图

> 截图与演示视频即将补充。应用目前处于 MVP 验收阶段（Phase 9），下述核心链路已端到端跑通。

## 工作原理

1. 按住全局热键（默认**右 Option**）说话。
2. 松手后本地转写（WhisperKit small，约 500 MB，端侧运行；模型下载完成前由 Speech 框架兜底）。
3. 原始转写经你自己的 LLM Key（OpenAI 兼容端点）润色为高质量工程 Prompt；超时/失败自动回退原文。
4. 结果注入到你按下热键那一刻正在使用的 App 输入框。

目标端到端延迟（松手到上屏）：**≤ 2 秒**（P95，15 秒以内语音）。

## 功能特性

- **按住说话全局热键** —— 默认右 Option；200ms 防误触确认、300ms 误触取消、Esc 放弃。热键预设：右 Option / 右 Command / 右 Shift / Fn。
- **本地隐私转写** —— WhisperKit small 完全端侧运行；音频仅存内存、不落盘；支持中英混合。
- **LLM 润色** —— 去口水词、句式规范化、结合上下文指代消解，带防脑补硬约束。自备 Key；超时/失败回退未润色原文；按住右 Option + Shift 可跳过润色。
- **上下文感知** —— 热键按下时快照前台 App 与窗口标题，松手时二次校验，并分类目标（终端 / 编辑器 / 浏览器 / 其他）。
- **剪贴板 + Cmd+V 注入** —— 带剪贴板快照/恢复与 changeCount 竞争保护；可选粘贴后自动回车；CLI 目标默认折叠换行。
- **非激活录音 HUD** —— 波形、阶段状态与成败反馈；全屏、多 Space 可见，不抢焦点。
- **权限自检与优雅降级** —— 麦克风、输入监控、辅助功能；一键跳转系统设置；无热键时菜单栏点击录音；无辅助功能时仅剪贴板注入。
- **诊断日志** —— 分类 os_log + 落盘日志，设置页一键导出。
- **设置项** —— 热键预设、输入设备、转写引擎（WhisperKit / Speech）、LLM 端点/模型、注入行为、自动发送。

## 技术栈

- **语言/UI**：Swift 6 + SwiftUI / AppKit（菜单栏 App、无主窗口）
- **音频**：AVAudioEngine + AVAudioConverter（16kHz 单声道 Float32，内存缓冲）
- **全局热键**：CGEventTap（listen-only）
- **本地转写**：WhisperKit（whisper.cpp / Core ML），Speech 框架兜底
- **润色**：OpenAI 兼容 `chat/completions`（自备 Key，存 Keychain）
- **上下文**：NSWorkspace + Accessibility API
- **注入**：NSPasteboard + CGEvent（Cmd+V）
- **测试**：Swift Testing + 协议 mock（不依赖系统权限）

## AI 开发

本项目**由 AI 编程助手构建**：

| 工具 | 模型 |
| --- | --- |
| [Kimi Code CLI](https://www.kimi.com/) | Kimi K3 |
| [DeepSeek](https://platform.deepseek.com/) | V4 Pro |

> 🤖 代码通过 AI 协作生成、审查与优化。每次变更使用的模型见提交信息末尾的 trailer。

## 权限与隐私

Voxmit 需要三项 macOS 权限，每项被拒时都会优雅降级：

| 权限 | 解锁能力 | 缺失时降级 |
| --- | --- | --- |
| 麦克风 | 录音 | 硬阻塞；引导页引导开启 |
| 输入监控 | 全局热键 | 菜单栏点击开始/停止录音 |
| 辅助功能 | Cmd+V 注入与窗口上下文 | 仅剪贴板注入 + 手动粘贴提示 |

隐私：默认全本地转写；录音不落盘；首次启用 LLM 润色前明确告知且可关闭；API Key 仅存 Keychain。

## 快速开始

### 环境要求

- macOS 14+（推荐 Apple Silicon）
- Xcode 16+（Swift 6 工具链）

### 构建与测试

```bash
git clone https://github.com/scottli139/voxmit.git
cd voxmit
xcodebuild build -scheme Voxmit -destination 'platform=macOS'
xcodebuild test -scheme Voxmit -destination 'platform=macOS'
```

WhisperKit small 模型（约 500 MB）首次启动时下载；就绪前由 Speech 框架兜底。

## 项目结构

```
Voxmit/
├── Pipeline/          # VoicePipeline 状态机、时钟、模型、占位
├── Modules/           # 权限、热键、音频、转写、润色、上下文、注入、诊断、存储
├── UI/                # 设置、权限引导、录音 HUD
└── VoxmitApp.swift    # @main 菜单栏 App
VoxmitTests/           # Swift Testing 套件 + 协议 mock
docs/                  # 架构、测试、使用说明、实现笔记、官网
```

## 开发状态

Phase 0–8 已实现并验证（240 个单测全绿）；当前处于 **Phase 9：端到端联调与 MVP 验收**。任务看板见 [PLAN.md](PLAN.md)，FR 级范围见[需求文档](语音编程工具-需求分析与方案说明.md)。

## 贡献

欢迎各种形式的贡献——bug 报告、新功能、文档、测试、翻译。开发环境搭建与 PR 检查清单见 [CONTRIBUTING.md](CONTRIBUTING.md)。

- 🤖 本项目由 AI 构建，**欢迎 AI 辅助贡献**——`AGENTS.md` 是为你的 AI 编程助手准备好的上下文文件。
- 参与请遵守[行为准则](CODE_OF_CONDUCT.md)。

## 许可证

本项目采用 MIT 许可证——详见 [LICENSE](LICENSE)。

## 致谢

- 本地转写由 [WhisperKit](https://github.com/argmaxinc/WhisperKit) 提供
- 受语音输入工具生态（VoiceInk、Wispr Flow）与 AI CLI 工作流启发
