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

### Phase 0: 工程脚手架 ✅

> 目标：可构建运行的菜单栏空壳，后续所有模块的地基。结构按需求文档 §4.6。

- [x] Xcode 工程创建：macOS App 模板、Swift 6、deployment target macOS 14.0、App Target + 单测 Target
- [x] 构建设置：`LSUIElement=YES`、关闭 App Sandbox、开启 Hardened Runtime、`NSMicrophoneUsageDescription` 文案
- [x] SPM 依赖接入 WhisperKit（GRDB / Sparkle 到 V1.1 对应任务时再接）
- [x] 目录结构落地（Pipeline / Modules / UI / Resources，见需求文档 §4.6）
- [x] MenuBarExtra 菜单栏图标 + 状态占位（idle / recording / processing / failed）
- [x] Settings 场景骨架 + UserDefaults 设置读写（键清单见需求文档 §9.2）
- [x] KeychainHelper：`llm-api-key` 读写（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`）
- [x] 本地调试签名可跑（ad-hoc；Developer ID 签名 + 公证流水线属发布任务）

- 2026-08-17：Phase 0 落地。手写 objectVersion 70 的 `project.pbxproj`（双 target 用 PBXFileSystemSynchronizedRootGroup，后续新增源码文件免改 pbxproj）+ 共享 scheme；WhisperKit 0.18.0 接入（upToNextMajorVersion ≥ 0.9.0）。
- 2026-08-17：验证全绿——`xcodebuild -list` / `-resolvePackageDependencies` / `build` / `test`（Swift Testing 2 用例通过：设置默认值注册、Pipeline 初始状态与图标）。
- 2026-08-17：签名用 ad-hoc（`CODE_SIGN_IDENTITY="-"`，本机钥匙串里的 Developer ID 属别家公司、不可用）；ad-hoc 下 codesign 忽略 Hardened Runtime（构建日志有 note），`ENABLE_HARDENED_RUNTIME=YES` 设置保留，发布构建（Developer ID + 公证）时生效。
- 2026-08-17：坑——构建设置正确名是 `GENERATE_INFOPLIST_FILE`（不是 `GENERATE_INFOPLIST`，无效设置曾致测试 target 签名失败）；GitHub 连接间歇性超时，SPM 解析靠重试循环完成。
- 2026-08-17：`Resources/` 与 Hotkey/Audio 等 Modules 子目录暂无内容未建，随对应 Phase 建立；`llm.model` 默认 `moonshot-v1-8k`（§9.2 交由实现按服务商文档定，选低价通用模型，用户可改）。

### Phase 1: 权限自检与引导 ✅ (FR-G5)

依赖：Phase 0

- [x] PermissionManager：三权限检测封装（麦克风 `AVCaptureDevice.authorizationStatus` / 输入监控 `CGPreflightListenEventAccess` / 辅助功能 `AXIsProcessTrusted`）
- [x] 权限自检页：状态总览 + 逐项"打开系统设置"深链 + 状态自动刷新
- [x] 首次启动引导流程（麦克风 → 输入监控 → 辅助功能；辅助功能可跳过、降级运行）
- [x] 降级模式贯穿：无输入监控 → 菜单栏点击开始/停止录音；无辅助功能 → 仅剪贴板注入（需求文档 §4.4 矩阵）

- 2026-08-17：Phase 1 落地。新增 `Modules/Permissions/PermissionManager.swift`（PermissionChecking 协议 + SystemPermissionChecker + PermissionManager + PermissionSnapshot，降级决策收敛在快照上）、`UI/PermissionOnboardingView.swift`（状态总览 + 深链 + Timer 每秒轮询，窗口关闭自动停止）、`UI/PermissionOnboardingWindowController.swift`（NSWindow 手动托管）、`VoxmitAppDelegate.swift`（首启判定 + 快照经 Combine 同步给 Pipeline）；菜单栏新增「权限自检…」、权限缺失提示、无输入监控时的录音降级入口占位（Phase 2 接线）。
- 2026-08-17：深链实测（macOS 26.6）三条全部有效：`…?Privacy_Microphone` / `?Privacy_ListenEvent` / `?Privacy_Accessibility` 均打开系统设置并路由到隐私与安全性面板（SecurityPrivacyExtension 进程启动为证）；子页面锚点导航无法从 shell 程序化确认（构建机无屏幕录制/AX 权限），列入手动验收项，验证方法与证据见 `docs/implementation-notes.md`。
- 2026-08-17：坑——`@Published private(set)` 的 `$` 投影对外不可写，`assign(to: &$x)` 跨类型编译失败，改 sink + `applyPermissionSnapshot` 方法；单测以 App 为宿主（TEST_HOST）会真实启动 App，applicationDidFinishLaunching 里用 `XCTestConfigurationFilePath` 环境变量守卫，避免测试运行时弹引导窗/接真实权限。
- 2026-08-17：验证全绿——build 成功、test 18 用例通过（快照组合/降级矩阵/Manager mock 行为/首启判定矩阵/Pipeline 降级标记/引导标记默认值）。授权弹窗、引导页视觉、菜单实际展示属手动验收项（见 `docs/TESTING.md` 权限路径）。

### Phase 2: 全局热键与状态机 ✅ (FR-B1, FR-B5)

依赖：Phase 0、Phase 1

- [x] CGEventTap **listen-only** 监听 `flagsChanged`，右 Option（keyCode 0x3D）按下/松开判定（需求文档 §4.2.1）
- [x] `tapDisabledByTimeout` / `tapDisabledByUserInput` 监听与自动恢复；RunLoop source 失效重建
- [x] VoicePipeline 状态机（需求文档 §3.4.1）：200ms 防误触、300ms 误触取消、Esc 取消（FR-B5）、旁路修饰键判定（FR-D4 输入）
- [x] 菜单栏点击录音的降级触发路径
- [x] 单测：状态机时序全路径（mock 时钟与事件源，清单见 `docs/TESTING.md`）

- 2026-08-17：Phase 2 落地。新增 `Modules/Hotkey/HotkeyManager.swift`（listen-only tap + `HotkeyEventParser` 纯解析器 + tap 自愈与 5s 看门狗）、`Pipeline/PipelineClock.swift`（时钟协议 + 真实时钟）、`Pipeline/PlaceholderServices.swift`（下游模块 no-op 占位）；VoicePipeline 重写为完整状态机（依赖全协议注入）；菜单降级入口接活（`handleMenuToggle`，无麦克风权限时禁用）；§9.1 三个异步协议补 `Sendable` 约束。
- 2026-08-17：坑（测试基建，详见 implementation-notes）——① 非隔离异步协议方法跑在协作线程池，MockClock 裸字典被主线程 cancel 与池线程注册并发踩踏致 SIGSEGV，mock 内部状态必须加锁；② Date 以 2001 纪元存秒（大基数 Double 误差 ~1e-7），"恰好 300ms"边界断言不可行，改 ±1ms 逼近；③ 虚拟时钟 sleep 必须锚定 keyDown 绝对时刻（任务调度晚于 advance 的竞态）；④ 异步链路等待用"主 Actor 探针×N"（FIFO 确定），不用定长 sleep。
- 2026-08-17：环境坑——本机 DerivedData 在外置盘，一旦有测试失败，Swift Testing 的进程内符号化（CoreSymbolication 读二进制）会卡数分钟呈假死状；`script -q /dev/null xcodebuild ...` 给 pty 让输出行缓冲可实时观察。
- 2026-08-17：验证全绿——build 成功、test 42 用例通过（Phase 0/1 的 18 + 新增 24：状态机 17 + 热键解析器 7）。真实右 Option 按住/松开、Esc、tap 被系统回收后的恢复属真机手动验收项。
- 2026-08-18：真机 bug 修复——keyUp 丢失（热键冲突干扰/tap 临时禁用/安全输入）导致解析器卡死 pressed=true、热键永久失效需重启 App；新增状态对账自愈（`HotkeyEventParser.synced(withCurrentFlags:)` + 看门狗/tapDisabled 恢复/tap 重建三时机，`CGEventSource.flagsState(.hidSystemState)` 读真实修饰位，保守只合成 hotkeyUp、反向只重置不发事件）；检测与对账共用 `hotkeyFlag`。build/test 全绿（90 用例，解析器 +4）；真机复现验证见 docs/implementation-notes.md 已知问题条目。
- 2026-08-18：FR-B2 最小可用版提前落地 MVP（动机：右 Option 与微信语音输入快捷键冲突，真机实测）——`HotkeyPreset` 预设四档（右 Option 0x3D / 右 Command 0x36 / 右 Shift 0x3C / Fn 0x3F，`eventFlag` 补 `.maskSecondaryFn` 映射）；设置页新增热键预设 Picker；HotkeyManager 监听 `UserDefaults.didChangeNotification` 热替换解析参数（tap 事件流不动，旧键 pressed 残留先合成 hotkeyUp 归位）；热键与旁路同修饰位（右 Shift + Shift 旁路）时旁路自动禁用；完整自定义录入仍留 V1.1。单测 +7（97 总），build/test 全绿。

### Phase 3: 音频采集 ✅ (FR-A1, FR-A2, FR-A3)

依赖：Phase 0

- [x] AVAudioEngine 采集 + AVAudioConverter 重采样 16kHz mono Float32，内存缓冲不落盘
- [x] 50ms 电平（RMS → dBFS）发布，供 HUD 波形
- [x] 设备热切换：ConfigurationChange 重建 engine 续录、已录部分保留；指定设备断开回落系统默认并提示
- [x] 5 分钟上限自动走"松手"流程并提示（FR-A3）；静音前缀裁剪
- [x] 麦克风权限被拒 / 无输入设备的错误路径

- 2026-08-17：Phase 3 落地。新增 `Modules/Audio/`：`AudioProcessing.swift`（AudioLevelMeter 电平 / SilenceTrimmer 静音前缀裁剪 / PCMResampler 重采样 / InputDeviceResolver 设备决策，全部纯逻辑可单测）与 `AudioCapture.swift`（`AudioCapturing` 实装 + MaxDurationWatchdog 上限看门狗 + InputDeviceCatalog/Lookup 设备枚举与查询）；Pipeline 接入静音前缀裁剪与真实 audio（delegate 注入替换 NoOp 占位，5 分钟回调接 `handleMaxRecordingDuration`）；设置页输入设备 Picker 生效（空串 = 系统默认）。
- 2026-08-17：坑——AVAudioConverter SRC 启动延迟实测缺口 ~176–240 帧（≈11–15ms @16k，恒定不随流增长，秒级录音可忽略），单测按实测容忍区间断言；`AVAudioConverterOutputStatus` 没有 `noDataNow` 成员（那是输入侧 `AVAudioConverterInputStatus`）；`inputNode.audioUnit` 是 Optional；看门狗计时锚定 `start()` 调用时刻（同 Phase 2 的"任务调度晚于时钟推进"竞态）。
- 2026-08-17：验证全绿——build 成功、test 63 用例通过（42 + 新增 21：电平 4 / 静音裁剪 5 / 重采样 4 / 设备决策 4 / 看门狗 3 / 裁剪接线 1）。真实录音质量、拔插设备热切换、5 分钟上限触发、权限拒绝路径属真机手动验收项。

### Phase 4: 录音 HUD ✅

依赖：Phase 2（状态机）、Phase 3（电平）

- [x] 非激活面板（`NSPanel` + `.nonactivatingPanel`）：实时波形 + 当前目标 App 名 + 阶段状态（录音/转写/润色/注入）
- [x] `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`：全屏终端、多 Space 可见
- [x] 反馈态：成功对勾淡出 / 取消静默 / 失败原因与"未润色"角标 / "已复制请手动粘贴"提示

- 2026-08-18：Phase 4 落地。新增 `UI/RecordingHUD.swift`（HUDVisibility 停留决策 + LevelHistory 波形历史 + RecordingHUDViewModel/View/Controller）；Pipeline 最小扩展：`targetSnapshot` 转 `@Published`、`lastInjectionReport`（InjectionReport = 档位 + wasRefined，"未润色"角标与 clipboardOnly 提示的数据源）、`InjectionOutcome` 补 Equatable；位置取主屏可见区域底部居中。
- 2026-08-18：关键设计——状态机保持"终止态即刻回 idle"不变，停留计时在 HUD 侧（HUDVisibility 纯函数决策延迟，Controller 按 PipelineClock 调度）；两处需对"终止态后紧跟的 idle"去抖：Controller 已有 hideTask 时忽略该 idle、ViewModel 锁存终止态展示（否则成功对勾会被瞬间清空）。
- 2026-08-18：验证全绿——build 成功、test 86 用例通过（63 + 新增 23：可见性矩阵 7 / 波形历史 4 / 提示映射 1 / 视图模型 7 / Pipeline 报告 4）。nonactivating 焦点保持、全屏/多 Space 可见性、各反馈态视觉属真机手动验收项。
- 2026-08-18：架构设计文档 `docs/ARCHITECTURE.md` 建立（设计意图 + Phase 0–4 as-built 实况；§12 记录与需求文档的偏离点）；AGENTS.md 与 README.md 文档地图同步收录。

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
