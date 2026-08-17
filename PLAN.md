# Voxmit 开发计划

> macOS 菜单栏常驻的语音驱动 AI 编程工具 —— 按住热键说话，润色后的 Prompt 自动注入当前 AI 开发工具

## 项目信息

- **项目名称**: Voxmit（2026-08-17 定名，见需求文档 §8-5）
- **仓库**: https://github.com/scottli139/voxmit（Private）
- **技术栈**: Swift 6 + SwiftUI/AppKit · WhisperKit · OpenAI 兼容 LLM 接口
- **目标平台**: macOS 14 Sonoma 及以上，优先 Apple Silicon
- **需求唯一事实来源**: `语音编程工具-需求分析与方案说明.md`（FR 编号、优先级、验收标准以它为准；本文件不复制需求内容，只跟踪任务与进度）
- **本文件定位**: 唯一的任务看板与进度记录，不在其他文件重复维护任务清单

---

## 开发进度

> 状态标记：✅ 已完成 / ⏳ 进行中 / 📋 未开始。任务后括号内为对应的需求文档 FR 编号或章节。

### Phase 0: 工程脚手架 📋

> 目标：可构建运行的菜单栏空壳，后续所有模块的地基。结构按需求文档 §4.6。

- [ ] Xcode 工程创建：macOS App 模板、Swift 6、deployment target macOS 14.0、App Target + 单测 Target
- [ ] 构建设置：`LSUIElement=YES`、关闭 App Sandbox、开启 Hardened Runtime、`NSMicrophoneUsageDescription` 文案
- [ ] SPM 依赖接入 WhisperKit（GRDB / Sparkle 到 V1.1 对应任务时再接）
- [ ] 目录结构落地（Pipeline / Modules / UI / Resources，见需求文档 §4.6）
- [ ] MenuBarExtra 菜单栏图标 + 状态占位（idle / recording / processing / failed）
- [ ] Settings 场景骨架 + UserDefaults 设置读写（键清单见需求文档 §9.2）
- [ ] KeychainHelper：`llm-api-key` 读写（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`）
- [ ] 本地调试签名可跑（Developer ID；公证流水线属发布任务）

### Phase 1: 权限自检与引导 📋 (FR-G5)

依赖：Phase 0

- [ ] PermissionManager：三权限检测封装（麦克风 `AVCaptureDevice.authorizationStatus` / 输入监控 `CGPreflightListenEventAccess` / 辅助功能 `AXIsProcessTrusted`）
- [ ] 权限自检页：状态总览 + 逐项"打开系统设置"深链 + 状态自动刷新
- [ ] 首次启动引导流程（麦克风 → 输入监控 → 辅助功能；辅助功能可跳过、降级运行）
- [ ] 降级模式贯穿：无输入监控 → 菜单栏点击开始/停止录音；无辅助功能 → 仅剪贴板注入（需求文档 §4.4 矩阵）

### Phase 2: 全局热键与状态机 📋 (FR-B1, FR-B5)

依赖：Phase 0、Phase 1

- [ ] CGEventTap **listen-only** 监听 `flagsChanged`，右 Option（keyCode 0x3D）按下/松开判定（需求文档 §4.2.1）
- [ ] `tapDisabledByTimeout` / `tapDisabledByUserInput` 监听与自动恢复；RunLoop source 失效重建
- [ ] VoicePipeline 状态机（需求文档 §3.4.1）：200ms 防误触、300ms 误触取消、Esc 取消（FR-B5）、旁路修饰键判定（FR-D4 输入）
- [ ] 菜单栏点击录音的降级触发路径
- [ ] 单测：状态机时序全路径（mock 时钟与事件源，清单见 `docs/TESTING.md`）

### Phase 3: 音频采集 📋 (FR-A1, FR-A2, FR-A3)

依赖：Phase 0

- [ ] AVAudioEngine 采集 + AVAudioConverter 重采样 16kHz mono Float32，内存缓冲不落盘
- [ ] 50ms 电平（RMS → dBFS）发布，供 HUD 波形
- [ ] 设备热切换：ConfigurationChange 重建 engine 续录、已录部分保留；指定设备断开回落系统默认并提示
- [ ] 5 分钟上限自动走"松手"流程并提示（FR-A3）；静音前缀裁剪
- [ ] 麦克风权限被拒 / 无输入设备的错误路径

### Phase 4: 录音 HUD 📋

依赖：Phase 2（状态机）、Phase 3（电平）

- [ ] 非激活面板（`NSPanel` + `.nonactivatingPanel`）：实时波形 + 当前目标 App 名 + 阶段状态（录音/转写/润色/注入）
- [ ] `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`：全屏终端、多 Space 可见
- [ ] 反馈态：成功对勾淡出 / 取消静默 / 失败原因与"未润色"角标 / "已复制请手动粘贴"提示

### Phase 5: 本地转写 📋 (FR-C1)

依赖：Phase 3

- [ ] `TranscriptionEngine` 协议（需求文档 §9.1）+ 引擎注册与运行时切换
- [ ] WhisperKit 集成：small 模型（~500MB）下载流程（后台 + 进度 + 断点续传 + 落盘校验）+ `transcribe`
- [ ] Speech 框架兜底引擎（模型下载完成前自动使用）
- [ ] 空音频 / 纯静音 → 空串静默结束路径
- [ ] 单测：mock 引擎、下载状态机

### Phase 6: Prompt 润色 📋 (FR-D1, FR-D4)

依赖：Phase 5、Phase 7

- [ ] OpenAI 兼容 `chat/completions` client（baseURL / model 可配，Key 从 Keychain 读取）
- [ ] System prompt 模板落地（需求文档 §9.1）+ 上下文组装（选区 ≤ 2KB 截断）
- [ ] 3s 总超时 + 1 次快速重试（退避 300ms）+ 回退原文（返回 `refined` 标记）
- [ ] 未配置 Key 直出模式；首次启用润色的隐私告知弹窗
- [ ] 单测：超时 / 失败 / 旁路 / 截断矩阵

### Phase 7: 上下文快照 📋 (FR-E1, FR-F5)

依赖：Phase 2（keyDown 时机）

- [ ] TargetSnapshot：keyDown 瞬间 `frontmostApplication`（PID / bundleID / 名称）+ AX 焦点窗口标题（需求文档 §3.4.3）
- [ ] bundleID → AppCategory 适配表（终端 / 编辑器 / 浏览器 / 其他）
- [ ] 松手时前台校验（录音中 Cmd+Tab 切换场景，以松手时前台为准）
- [ ] 无 AX 权限降级为"仅 App 名"
- [ ] 单测：分类表与降级矩阵

### Phase 8: 结果注入 📋 (FR-F1, FR-F4, FR-F5)

依赖：Phase 7

- [ ] ClipboardInjector 主流程：剪贴板快照 → 写入文本 → `CGEventPost` Cmd+V → ~300ms 后恢复原剪贴板
- [ ] `changeCount` 竞争保护：用户复制了新内容则放弃恢复
- [ ] 辅助功能权限缺失 / 目标不可编辑 → 仅剪贴板 + HUD 提示"已复制，Cmd+V 手动粘贴"
- [ ] 换行折叠（CLI 目标默认折叠为空格）+ bundleID 注入适配层配置表
- [ ] FR-F4 自动发送开关（默认关）：粘贴后 ~150ms 模拟 Return
- [ ] 单测：注入决策与全部降级路径

### Phase 9: 联调与 MVP 验收 📋

依赖：Phase 1–8

- [ ] 端到端链路联调（需求文档 §4.3 时序全路径）
- [ ] 性能实测：20 次 15s 语音取 P95 ≤ 2s（对照需求文档 §1.3 预算表）
- [ ] 目标 App 注入矩阵手动测试（`docs/TESTING.md` 清单）
- [ ] 三权限拒绝 / 运行中撤销的降级路径走查
- [ ] 需求文档 §5 MVP 验收清单全部通过

### V1.1（第 3–4 周）📋

> 范围以需求文档 §5 为准：AX 上下文（FR-E2/E3）与指代消解（FR-D2）、流式转写（FR-C2）、AX 写入注入、预览浮层（FR-F3）、点按模式（FR-B3）、热键自定义（FR-B2）、提示音（FR-A4）、历史记录（FR-G2，接入 GRDB）、自定义词表（FR-C4）、润色风格（FR-D3）、Sparkle 自动更新。

### V2（第 5–8 周）📋

> 范围以需求文档 §5 为准：CLI stdin 直通（FR-F2，Kimi Code 专项）、MCP Server（FR-H1）、语音指令集（FR-H2）、TTS 播报（FR-G4）。启动前提：需求文档 §8 第 1–4 项已决策（2026-08-17）；商业形态在 V2 启动前最终拍板。

---

## 下一步行动

**第一波（MVP，约 2 周，顺序含依赖约束）：**

1. **Phase 0 工程脚手架**（一切的前提；模型下载流程尽早跑通，~500MB 不阻塞本地转写联调）
2. **Phase 1 权限自检**（后续模块的降级逻辑依赖它）
3. **Phase 2 热键 + Phase 3 音频**（相互独立，可并行）
4. **Phase 4 HUD**（依赖 2、3 的接口先行约定）
5. **Phase 7 快照 → Phase 6 润色 → Phase 8 注入**（顺序依赖，接口按需求文档 §9.1）
6. **Phase 5 转写联调** → **Phase 9 联调验收**

**工程化（随 Phase 0 同步落地）：** SwiftLint / SwiftFormat 配置、GitHub Actions CI（编译 + 单测）、`.gitignore`（Xcode / 模型文件 / 签名材料）。

**暂缓项（等排期）：** GRDB 历史记录与 Sparkle（V1.1）、LICENSE / README / 官网（§8-4 已决策：暂缓定形，代码按可开源组织）、历史记录加密（§8-3 已决策：列为 P2）。

---

## 注意事项

1. **开发环境**：macOS 14+、Xcode 16+；真机调试需为开发构建逐项授予三项系统权限（麦克风 / 输入监控 / 辅助功能）
2. **模型文件**：WhisperKit 模型（~500MB）不进 git，运行时下载至 Application Support，`.gitignore` 排除
3. **密钥**：LLM API Key 只存 Keychain；代码、配置、日志中禁止出现
4. **Session 记录**：重要开发日志直接附在对应 Phase 条目之后（一行一事，含日期）；本文件臃肿后再归档至 `docs/session-log.md`
