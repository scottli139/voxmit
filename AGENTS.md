# AGENTS.md

> 本文件面向 AI 编程代理，介绍本项目的现状、目标与约定。阅读前请假设自己对项目一无所知。

## 1. 项目现状（重要）

**Phase 0 工程脚手架、Phase 1 权限自检与引导（FR-G5）已完成（2026-08-17）：Xcode 工程可构建、可测试；热键/音频/转写/润色/注入等功能模块尚未实现，从 Phase 2 起按 `PLAN.md` 推进。**

- 需求文档 `语音编程工具-需求分析与方案说明.md`（v0.8，2026-08-18；§8 开放问题已全部决策，定名 Voxmit）是需求与方案的唯一事实来源。
- 仓库：https://github.com/scottli139/voxmit（Private，2026-08-17 创建）。
- 构建与测试命令（CI 尚未建立，本地执行）：
  - `xcodebuild build -scheme Voxmit -destination 'platform=macOS'`
  - `xcodebuild test -scheme Voxmit -destination 'platform=macOS'`
- 工程要点：手写 pbxproj（objectVersion 70，`Voxmit/` 与 `VoxmitTests/` 为文件系统同步分组，新增源码文件免改 pbxproj）；签名走 xcconfig 分层——`Configurations/Signing.xcconfig`（入库，默认 ad-hoc）+ `Configurations/LocalSigning.xcconfig`（gitignored，本机 Developer ID 覆盖；证书名称/Team ID 属本地私有信息，禁止提交，2026-08-19 起本机已启用稳定签名，TCC/Keychain 授权跨构建持久）；Debug 构建本机关闭 hardened runtime（macOS 26：Developer ID + runtime + 未公证 → 麦克风授权静默拒绝，见 implementation-notes）；Swift 6 严格并发。踩坑记录见 `PLAN.md` Phase 0 的 Session 记录。
- §4 的模块划分目前仅落地了工程骨架与接口契约（需求文档 §9.1）；实现模块时以需求文档 §4.2/§3.4 为准，不要臆造尚未实现的行为。

### 文档地图

| 文件 | 内容 |
|---|---|
| `语音编程工具-需求分析与方案说明.md` | 需求与方案唯一事实来源（FR 编号、优先级、里程碑、接口契约 §9.1） |
| `docs/ARCHITECTURE.md` | 架构设计文档：设计意图 + Phase 0–4 as-built 实况（分层、状态机、模块边界、并发模型） |
| `PLAN.md` | 开发计划与任务进度（唯一的任务看板，不在本文件重复维护） |
| `CONTRIBUTING.md` | 贡献指南：环境搭建、提交前检查链、代码质量要求、Commit/PR 规范 |
| `docs/TESTING.md` | 测试要求：质量门禁、单测规范、真机手动测试矩阵、性能验收方法、CI 规划 |
| `docs/implementation-notes.md` | 实现细节知识库：踩坑、架构要点、发布流程（实现开始后填充） |
| `docs/USER_GUIDE.md` | 用户使用说明（面向最终用户；用户可见行为变更时随提交同步更新） |

## 2. 项目概述

**Voxmit**——一款 macOS 菜单栏常驻的语音驱动 AI 编程工具。（2026-08-17 定名；仓库 https://github.com/scottli139/voxmit，Private）

核心链路：按住全局热键（默认右 Option）说话 → 本地语音转写 → LLM 润色为高质量工程 Prompt → 自动注入当前 AI 开发工具（Kimi Code / Claude Code / Cursor 等）的输入框。

定位：不做通用语音输入，做"面向 AI 编程的语音入口"。差异化在于上下文感知（选区代码、文件路径、CLI 会话状态）、Prompt 工程化润色、与 AI CLI 的 stdin/MCP 深度集成。

关键指标（详见文档 §1.3）：松手到上屏端到端延迟 ≤ 2 秒；润色后 Prompt 可用率 ≥ 80%。

## 3. 技术栈与目标平台（计划）

| 项 | 选型 |
|---|---|
| 语言 / UI | Swift 6 + SwiftUI（AppKit 互操作），菜单栏 App、无主窗口 |
| 目标平台 | macOS 14 Sonoma 及以上，优先 Apple Silicon（Intel 降级云端转写） |
| 音频采集 | AVAudioEngine，16kHz 单声道 PCM，监听设备热切换 |
| 全局热键 | CGEventTap（`CGEvent.tapCreate` 拦截 flagsChanged 实现按住/松开语义） |
| 本地 ASR | WhisperKit（whisper.cpp 的 Core ML 移植，默认）；Speech 框架（备选）；云端 ASR（可选增强） |
| LLM 润色 | OpenAI 兼容协议接口（可配 Kimi/Moonshot），API Key 存 Keychain |
| 上下文感知 | NSWorkspace + Accessibility API（AXUIElement） |
| 结果注入 | NSPasteboard + 模拟 Cmd+V（P0）；AX 直接写入（P1）；CLI stdin 直通（P1） |
| 存储 | GRDB（SQLite）存历史记录；UserDefaults 存设置 |
| 自动更新 | Sparkle（EdDSA 签名校验） |
| 参考实现 | VoiceInk（开源 Swift 同类工具，架构可直接借鉴） |

## 4. 架构与模块划分（计划，对应文档 §4.2）

创建工程时请按以下模块组织代码，名称沿用文档命名：

- **VoicePipeline**（Phase 2 已落地状态机）—— 主链路状态机协调器（文档 §3.4.1 / §4.2.0）；按键时序判定（200ms 防误触、300ms 误触取消、5 分钟上限、旁路修饰键）集中在此层；下游依赖全部协议注入（时钟 `PipelineClock` + §9.1 协议 + `AudioCapturing` / `ContextCollecting`），占位实现见 `Pipeline/PlaceholderServices.swift`。
- **PermissionManager**（Phase 1 已落地，`Modules/Permissions/`）—— 三权限检测与引导（文档 §4.4 权限矩阵）；系统 API 收敛在 `PermissionChecking` 协议后便于 mock；降级决策收敛在纯值类型 `PermissionSnapshot`（无输入监控 → 菜单栏点击录音；无辅助功能 → 仅剪贴板注入），快照经 Combine 实时同步给 VoicePipeline。
- **HotkeyManager**（Phase 2 已落地，`Modules/Hotkey/`）—— 全局热键；默认右 Option 按住说话（Push-to-Talk），CGEventTap **listen-only**（只需"输入监控"权限）；Esc 取消录音；`HotkeyEventParser` 纯解析器承载判定逻辑（可单测），tap 失效自动恢复 + 看门狗巡检重建；热键冲突检测与自定义（FR-B2）属 P1 未做。
- **AudioCapture**（Phase 3 已落地，`Modules/Audio/`）—— 音频采集；AVAudioEngine + AVAudioConverter 重采样 16kHz mono Float32，仅存内存不落盘；50ms 电平发布（Combine）、5 分钟上限看门狗（`MaxDurationWatchdog`，回调接 `VoicePipeline.handleMaxRecordingDuration`）、设备热切换重建续录；纯逻辑（电平/静音裁剪/重采样/设备决策）拆在 `AudioProcessing.swift` 可单测。
- **RecordingHUD**（Phase 4 已落地，`UI/RecordingHUD.swift`）—— 非激活 NSPanel 录音浮层（不抢焦点、全屏/多 Space 可见）；波形 + 阶段状态 + 反馈态（成功/未润色角标/手动粘贴/失败）；停留时长由 `HUDVisibility` 纯函数决策、计时在 HUD 侧（状态机终止态保持即刻回 idle）；反馈数据源自 Pipeline 的 `lastInjectionReport`。
- **TranscriptionEngine** —— 转写引擎抽象为协议，WhisperKit（默认 small 模型）/ Speech / 云端可运行时切换；支持自定义热词词表。
- **PromptRefiner**（Phase 6 已落地，`Modules/Refiner/`）—— LLM 润色（去口水词、句式规范化、指代消解）；OpenAI 兼容端点（Keychain 存 Key），3s 预算（1.2+0.3+1.5）超时/失败回退注入原文；首次实际发送前隐私告知门（`llm.privacyAcknowledged`）；旁路开关（右 Option+Shift 跳过润色）。
- **ContextCollector** —— 前台 App 识别、选中文本/光标读取；热键按下时快照注入目标（FR-F5，见文档 §3.4.3）；无权限时静默降级为"无上下文"模式。
- **Injector** —— 三档注入：剪贴板+模拟粘贴（通用兜底，模拟按键需"辅助功能"权限）/ AX 写入（`AXSelectedText` 光标处插入，禁止覆盖已有输入）/ CLI stdin 直通；注入前预览浮层（P1）；注入后恢复原剪贴板内容。
- **MCP Server（V2）** —— 暴露 `listen_voice` 工具，供 AI Agent 主动调用获取语音输入。

主链路时序见文档 §4.3；功能优先级（P0/P1/P2）见文档 §3.1。

## 5. 开发约定

- **文档与注释语言**：项目文档使用简体中文；代码标识符用英文，注释风格跟随 Swift 社区惯例。
- **需求变更**：功能需求、优先级、里程碑以 `语音编程工具-需求分析与方案说明.md` 为唯一事实来源。修改行为前先核对文档中的 FR 编号与优先级定义（P0 = MVP 必须）。
- **最小改动**：按优先级实现，不要提前实现 P1/P2 功能。
- **任务看板**：任务进度只更新 `PLAN.md`，不在本文件维护任务清单。
- **实现细节沉淀**：踩坑与架构要点写入 `docs/implementation-notes.md`；本文件只保留精简指南。
- **使用说明同步**：用户可见行为（界面、设置项、操作方式、权限与降级行为）变更时，同一次提交内顺手更新 `docs/USER_GUIDE.md`。
- **文档图示**（2026-08-18 起）：项目文档中**禁止 ASCII 图**（框线/箭头字符画，中英文混排对不齐）；图示一律用 mermaid（```mermaid 代码块，GitHub 原生渲染），确有需要时生成真实图片存 `docs/images/` 引用。目录树等纯文本列表不受此限，但不做列对齐。mermaid 写法注意：flowchart 边标签（`-->|...|`）含半角括号等语法字符时必须用双引号包裹（`-->|"..."|`，全角括号不受影响），标签中含 `<`/`>` 开头文本需改写防 HTML 误判。
- **提交前检查链与代码质量要求**：见 `CONTRIBUTING.md`（Phase 0 工程建立后生效）。AI 协助的提交须在 commit message 末尾加 `Model: <模型名>` trailer。
- **约定同步**：修改本文件提及的任何约定（文档体系、工作流、检查链）时，同步更新本文件。

## 6. 安全与隐私 considerations

- **权限**：需要三项系统权限——麦克风（必需）、辅助功能（上下文感知与注入）、输入监控（全局热键）。必须提供权限自检页与一键跳转系统设置的引导；权限被拒时降级运行而非崩溃。
- **隐私**：默认全本地处理（端侧转写）；调云端 LLM 润色须明确告知用户且可关闭；录音文件不落盘（或加密暂存后即删）。
- **敏感信息**：LLM API Key 必须存 Keychain，禁止硬编码或写入 UserDefaults；历史记录可能含代码片段——已决策（文档 §8-3）：明文 SQLite + 30 天/500 条滚动清理 + 一键清空，加密列为 P2 增强。
- **沙盒与分发**：因 CGEventTap 与 AX 能力受限，本工具**关闭 App Sandbox、不上 Mac App Store**，走官网分发；发布需 Developer ID 签名 + Apple 公证（Notarization）。

## 7. 测试策略

已建立：需求层面见需求文档 §9.3，工程化要求（质量门禁、单测规范、真机手动测试矩阵、性能验收方法、CI 规划）见 `docs/TESTING.md`。要点：核心逻辑（状态机、润色回退、注入降级、上下文打包、剪贴板恢复）以协议 mock 编写单元测试，不依赖系统权限；系统交互需真机手动验证。验收标准见需求文档 §5（MVP：终端中的 Kimi Code 内按住说话 → 松手 2 秒内润色后 Prompt 出现在输入框光标处）。

## 8. 里程碑（计划，详见文档 §5）

1. **MVP（第 1–2 周）**：菜单栏骨架 + 设置页、右 Option 按住说话、WhisperKit 转写、LLM 润色（含回退）、剪贴板+Cmd+V 注入、权限引导。
2. **V1.1（第 3–4 周）**：AX 上下文感知、流式转写、预览浮层、热键自定义、历史记录、自定义词表。
3. **V2（第 5–8 周）**：CLI stdin 直通（Kimi Code 专项）、MCP Server、语音指令集、TTS 播报。

## 9. 开放问题决策记录（需求文档 §8，2026-08-17 维护者已确认）

1. LLM 润色：默认 Kimi（Moonshot）OpenAI 兼容端点，用户自备 Key，MVP 不内置额度；
2. 模型下载：首次启动引导下载 WhisperKit small（约 500 MB），Speech 框架兜底，Intel 引导云端 ASR；
3. 历史记录：明文 SQLite + 30 天/500 条滚动清理 + 一键清空；加密列为 P2；
4. 商业形态：暂缓定形，代码按可开源组织；V2 启动前最终拍板；
5. 命名：已定名 **Voxmit**（2026-08-17，GitHub 查重 0 同名；仓库 scottli139/voxmit）；App Store / 商标查重在发布前补做。
