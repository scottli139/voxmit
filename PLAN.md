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
- 2026-08-18：真机修复——HUD 失败态长文案被截断（只剩一个"失"字）。根因：面板尺寸仅在 show() 时取一次且文案无换行约束，长句被 HStack 压缩截断。修法：文案列宽上限 320 + `lineLimit(3)` + `fixedSize(vertical:)`；hosting controller 开 `sizingOptions = .preferredContentSize`，KVO 订阅尺寸变化实时调整面板（`HUDLayout` 纯逻辑钳制 160–420 宽、防 resize 回环）；成功/角标等反馈态同口径。单测 +5（160 总），build/test 全绿。
- 2026-08-19：线上崩溃热修（EXC_BAD_ACCESS 主线程栈溢出，用户机 09:07 报告）：HUD 截断修复遗留的尺寸双重驱动——`sizingOptions.preferredContentSize`（AppKit `updateAnimatedWindowSize` 自动改窗）与 KVO 同步 `setContentSize` 互相触发 layout 递归至栈爆。修法：移除 sizingOptions（掐 AppKit 自动驱动）、resize 一律主队列异步合并派发（连续变化只应用最后一次）、尺寸计算改"文案属性变化 → sizeThatFits → 同一派发通道"；钳制/容差保留。崩溃要点与教训已录 implementation-notes 已知问题。build/test 全绿（173 例）。
- 2026-08-19：WhisperKit 转写语言锁定——短音频自动语言检测不可靠（真机：2 秒中文"喂喂喂123"被误判英文）。新增 `asr.whisperLanguage` 键（默认 "zh" 锁中文，"auto" 恢复自动检测，无 UI；锁中文后中英文混识不受影响），`WhisperLanguageResolver` 纯解析；`DecodingOptions(language:)` 取 ISO 639-1 码（包源码确认，"zh" 亦接受 "chinese"/"mandarin"）；转写日志补 language 字段。单测 +4（177 总），build/test 全绿。
- 2026-08-19：HUD 布局两 bug 修复（真机录屏逐帧确认）——① 波形溢出盖字：`LevelHistory` 24 条 × 5pt > 84pt 固定框天然越界，新增 `WaveformLayout` 纯几何（容量 17 条）+ suffix 滚动窗口 + 右对齐 + clipped 兜底；② 状态切换新旧文案并存：状态文本 `.id(statusText)` + `.transition(.identity)` 显式即时替换，同一时刻只显示当前态。单测 +3（180 总），build/test 全绿。

### Phase 5: 本地转写 ✅ (FR-C1)

依赖：Phase 3

- [x] `TranscriptionEngine` 协议（需求文档 §9.1）+ 引擎注册与运行时切换
- [x] WhisperKit 集成：small 模型（~500MB）下载流程（后台 + 进度 + 断点续传 + 落盘校验）+ `transcribe`
- [x] Speech 框架兜底引擎（模型下载完成前自动使用）
- [x] 空音频 / 纯静音 → 空串静默结束路径
- [x] 单测：mock 引擎、下载状态机

- 2026-08-18：Phase 5 落地。新增 `Modules/Transcription/`：`WhisperKitTranscriptionEngine`（activate 幂等/并发去重/变体切换重载）、`SpeechTranscriptionEngine`（端侧识别 + 语音识别 TCC 权限）、`ModelDownloadManager` + `ModelDownloading` 协议（状态机 notStarted→downloading(进度)→ready/failed 可重试；下载用 WhisperKit 内置静态方法，swift-transformers Downloader 自带断点续传与 Progress 回调、后台 session，落盘 Application Support/Voxmit/Models）、`TranscriptionEngineResolver` 纯决策 + `TranscriptionEngineRouter` 运行时热切换（模型未就绪自动 Speech 兜底）。
- 2026-08-18：配套改动——占位注入由"恒失败"改为 `PlaceholderClipboardInjector`（仅写剪贴板返回 clipboardOnly 档，转写文字松手后即可手动粘贴，完整注入 Phase 8）；`Info.plist` 新增 `NSSpeechRecognitionUsageDescription`（Speech 兜底引入第四个 TCC 权限，§4.4 矩阵未列，首次使用弹窗）；设置页转写区新增当前引擎显示与模型下载进度/重试。
- 2026-08-18：坑——@MainActor 类无法直接遵守 Sendable 协议（"conformance crosses into main actor-isolated code"），Router 改非隔离 + NSLock（use 主线程写/任意线程读）；`@Sendable` 闭包参数仍需显式 `@escaping`；WhisperKit 0.18 API：`WhisperKit(config:) async throws` + `loadModels()` + `transcribe(audioArray:)` + `static download(variant:downloadBase:useBackgroundSession:progressCallback:)`。
- 2026-08-18：验证全绿——build 成功、test 108 用例通过（97 + 新增 11：引擎决策 4 / 下载状态机 6 / 路由器 1）。真实下载 ~500MB 模型、WhisperKit 转写质量、Speech 兜底识别、权限弹窗属真机手动验收项。
- 2026-08-18：真机验收修复——huggingface.co 被墙致模型下载超时；源码核实 `WhisperKit.download` 的 `endpoint:` 参数支持自定义端点（HubApi 亦支持 HF_ENDPOINT 环境变量），落地官方 → hf-mirror.com 自动回退（`asr.modelRepoEndpoint` 键：auto/强制，无 UI）；swift-transformers Downloader 断点续传按本地路径记录、跨端点续传有效。
- 2026-08-18：日志设施落地——`Pipeline/AppLog.swift`（os.Logger，subsystem=com.voxmit.app，按模块分 category）；状态机转换/录音开始结束/下载端点尝试与成败/引擎切换与激活/注入结果/权限降级等关键事件打点；注意字符串插值须标 `privacy: .public`（否则 Console 屏蔽为 \<private\>）；排查方法见 implementation-notes。单测 +7（115 总），build/test 全绿。
- 2026-08-18：日志升级为产品级——门面化 `AppLog.info(.pipeline, "…")`（同时写 os_log 与内存环形缓冲 LogRingBuffer，保底本次会话诊断）；设置页新增「诊断」区「导出诊断日志…」（环境头 + 系统日志段 + 会话缓冲段，`Modules/Diagnostics/DiagnosticLogExporter.swift`）；日志规范（级别约定/隐私红线/打点原则）固化在 implementation-notes「日志设施」节。覆盖面补齐：HUD 显示隐藏、剪贴板写入成败、模型激活耗时、Speech 授权结果、转写耗时（仅元数据）。OSLogStore 本机三 scope 均不可用（logd 持久存储损坏，环境特例），导出自动降级内存缓冲段；单测 +11（126 总），build/test 全绿。
- 2026-08-18：日志落盘（参照 DDFileLogger 思路自实现，无第三方依赖）——AppLog 门面三路同写（os_log/环形缓冲/文件，调用点不变）；`Modules/Diagnostics/LogFileStore.swift`：`~/Library/Application Support/Voxmit/Logs/voxmit-yyyy-MM-dd.log` 按日命名追加写，串行队列异步落盘不阻塞主线程，写盘失败熔断降级；保留最近 7 个文件且总量 ≤20MB（启动 + 跨天滚动时清理，当天文件无条件保留）；启动写分隔行。测试宿主（TEST_HOST）不写盘。诊断导出环境头注明日志目录。单测 +10（136 总），build/test 全绿。
- 2026-08-18：真机验收修复两连——① 就绪误判卡死：残骸目录（首次官方端点超时遗留）被弱校验误判 ready → 幂等下载短路 → 激活失败永远 Speech；修法=`ModelFolderValidator.isReady`（变体目录需含完整产物集：`config.json` + `AudioEncoder/MelSpectrogram/TextDecoder.mlmodelc` 三个目录包）+ `ModelDownloadManager.markInvalidModel` 自愈（删除残骸目录强制干净重下 + 每会话自动重试一次，防循环闸；failed 态 resolve 落 speech 无死循环）。② 设置窗口不置顶（LSUIElement 经典坑）：SettingsView.onAppear 里 `NSApp.activate()`（macOS 14+ API）；权限自检页既有 makeKeyAndOrderFront+activate 无需改。单测 +10（146 总），build/test 全绿。
- 2026-08-18：就绪误判修复不彻底再修（真机日志实锤：残骸含部分 .mlmodelc 仍被"≥1 个"校验放行）——校验升级为完整产物集缺一不可；`ModelDownloading` 协议新增 `removeInvalidModel()`（按名匹配变体目录，不做就绪校验，删失败不阻塞）；教训与修复链见 implementation-notes。测试修三处自身缺陷：跨天用例竞态（append 异步入队须先 flush 再推进时钟）、建文件前未建目录、并行测试共享 AppLog 环形缓冲致全局计数断言失效（改唯一标记定位）。单测 149 总，build/test 全绿。
- 2026-08-18：真机日志再修两连——① Speech 兜底失败实因：系统级听写关闭（"Siri and Dictation are disabled"，运行时 AssistantServices 域，SDK 无公开错误码）→ `SpeechErrorMapper` 纯函数映射为可操作文案（系统设置 → 键盘 → 听写）；② nsurlsessiond 不可用（NSURLErrorDomain -997，与本机 logd 坏同源）→ 下载器端点循环内同端点先后台后前台回退一次（按错误码判定不匹配文案）；huggingface 超时属被墙正确行为不回退。单测 +6（155 总），build/test 全绿。
- 2026-08-18：模型下载器决策反转（真机最小复现确诊三连根因：镜像 resolve-cache HEAD 缺 Content-Length 触发 swift-transformers metadata 校验死、tokenizer 属另一仓库需独立联网被墙挂、删目录自愈会毁好文件）——弃用 `WhisperKit.download`，自实现 `Modules/Transcription/ModelRepoDownloader.swift`（tree API 清单 → 逐文件 GET + `.partial` Range 续传 + 完成校验 + 原子移动 + tokenizer 两文件落模型目录根离线激活）+ `URLSessionRepoHTTPClient.swift`（前台 data task 流式写盘通道）；`markInvalidModel` 去删除化（保留 failed + 每会话自动重试一次）；引擎激活 `WhisperKitConfig` 显式传 `downloadBase`；-997 回退逻辑随前台化移除。单测 +13/-5（173 总），build/test 全绿。
- 2026-08-18：HUD 失败态长文案截断修复（面板一次性定尺寸 + 文案无换行约束所致；文案列宽上限 320 + lineLimit(3) + fixedSize(vertical:)，hosting controller 开 `sizingOptions = .preferredContentSize` + KVO 订阅随内容调整面板，`HUDLayout` 纯逻辑钳制防回环）。Speech 兜底中文识别修复：默认 locale 英文识别中文出胡话——新增 `asr.speechLocale` 键（默认 zh-CN，无 UI），`SpeechLocaleResolver` 纯解析；端侧语言资产缺失（听写语言列表未加中文）与不支持 locale 分别映射 `onDeviceLanguageMissing` / `localeUnsupported` 可操作文案；`requiresOnDeviceRecognition = true` 端侧口径不变。单测 +5（165 总），build/test 全绿。

### Phase 6: Prompt 润色 ✅ (FR-D1, FR-D4)

依赖：Phase 5、Phase 7

- [x] OpenAI 兼容 `chat/completions` client（baseURL / model 可配，Key 从 Keychain 读取）
- [x] System prompt 模板落地（需求文档 §9.1）+ 上下文组装（选区 ≤ 2KB 截断）
- [x] 3s 总超时 + 1 次快速重试（退避 300ms）+ 回退原文（返回 `refined` 标记）
- [x] 未配置 Key 直出模式；首次启用润色的隐私告知弹窗
- [x] 单测：超时 / 失败 / 旁路 / 截断矩阵

- 2026-08-19：Phase 6 落地。新增 `Modules/Refiner/`：`LLMClient.swift`（`ChatCompleting` 协议 + `OpenAIChatClient`：makeRequest/parseContent 静态纯函数可单测，错误分类 missingAPIKey/httpStatus/invalidResponse，日志只落类别）、`RefinePrompt.swift`（§9.1 system prompt 原文 + user message 组装 + UTF-8 安全截断）、`PromptRefiner.swift`（3s 预算分配 1.2+0.3+1.5、TaskGroup 预算竞速、隐私门注入点）。
- 2026-08-19：隐私门设计——`llm.refineEnabled` 默认 true，挡在**首次实际发送前**（`llm.privacyAcknowledged` 键）：AppDelegate `confirmRefinePrivacy()` 弹 NSAlert（先 NSApp.activate 防 LSUIElement 藏窗），「继续」记键放行、「本次跳过」返回 false 不发请求且下次再问；单测注入 true/false 双路径。旁路（FR-D4 右 Option+Shift）在 Phase 2 已接入状态机，本期自然生效（跳过润色、wasRefined=false）。
- 2026-08-19：验证全绿——build 成功、test 197 用例通过（180 + 新增 17：直出矩阵/隐私门/重试恰好一次/双败回退/超时预算竞速（MockClock 不真睡）/2KB 截断 UTF-8 安全/请求体字段/客户端组装解析）。真实 API 调用（用户 Moonshot Key）属真机验收项。
- 2026-08-19：真机联调排障①日志增强——润色三条直出路径（开关关闭/未配 Key/FR-D4 旁路）补打点、attempt 失败带序号+单次耗时、成功带模型+输入输出字数、URLError 细化记 code、启动记录 LLM 设置快照（端点/模型/开关/有无 Key）、httpStatus 携带服务端响应体摘录（≤500 字符；请求体与 Key 永不落日志）。
- 2026-08-19：真机联调排障②Keychain 反复弹授权窗（润色一次连弹 4 次、启动也弹）——根因 ad-hoc 签名 ACL 无法持久信任且一次 SecItem 调用可连弹多窗；`KeychainHelper` 加进程内内存缓存（NSLock 串行首次读取），会话内只真实读一次，弹窗合并到启动期。
- 2026-08-19：真机联调排障③签名改 xcconfig 分层——`Configurations/Signing.xcconfig`（入库默认 ad-hoc + hardened runtime）+ `LocalSigning.xcconfig`（gitignored，本机 Developer ID 覆盖，证书信息禁止提交）；探针实证 **macOS 26「Developer ID + hardened runtime + 未公证 → 麦克风授权静默拒绝」**（无弹窗无 TCC 记录），本机 Debug 关 runtime 解决；此后 TCC 三项权限与 Keychain 信任跨构建持久。详见 implementation-notes。
- 2026-08-19：真机联调排障④temperature 400——Kimi Code 端点仅允许 temperature=1，请求体改为不携带 temperature（各服务商走默认值）。
- 2026-08-19：端点选型实测——Kimi Code 端点（kimi-for-coding 系列）结构性不适合润色后端：强制思考且计入 max_tokens（500 额度正文被吃光吐空串）、延迟 3~6.6s 超 3s 预算；Moonshot 开放平台 moonshot-v1-8k 实测 0.6~2s、无强制思考、工程口述质量达标。**真机验收通过**：转写 918ms → 首试 1.2s 超时（冷连接）→ 重试成功（润色 2364ms，11 字 → 31 字），`已润色=true`。

### Phase 7: 上下文快照 ✅ (FR-E1, FR-F5)

依赖：Phase 2（keyDown 时机）

- [x] TargetSnapshot：keyDown 瞬间 `frontmostApplication`（PID / bundleID / 名称）+ AX 焦点窗口标题（需求文档 §3.4.3）
- [x] bundleID → AppCategory 适配表（终端 / 编辑器 / 浏览器 / 其他）
- [x] 松手时前台校验（录音中 Cmd+Tab 切换场景，以松手时前台为准）
- [x] 无 AX 权限降级为"仅 App 名"
- [x] 单测：分类表与降级矩阵

- 2026-08-19：Phase 7 落地。新增 `Modules/Context/RealContextCollector.swift`（SystemWorkspace 协议隔离 NSWorkspace+AX——NSWorkspace 在 macOS 26 SDK 为 @MainActor 标注，assumeIsolated 限 Pipeline/测试主线程调用；降级矩阵：无 AX/无焦点窗口 → 仅 App 名，前台取不到 → 「无上下文」pid 0）+ `AppCategoryMapper`（纯表：Terminal/iTerm2/Warp/Ghostty/kitty/SecureCRT/Alacritty、VSCode/Cursor/Zed/Xcode/Sublime/JetBrains 前缀、Safari/Chrome/Firefox/Brave/Edge/Arc，未知 → other）。
- 2026-08-19：松手校验（§3.4.3）——handleHotkeyUp 必二次快照，bundleID/pid 变化打 NOTICE 并以松手前台为准（注入目标与润色上下文同步）；VoiceContext.appCategory 由 AppCategoryMapper 真实分类（替换 .other 硬编码）；「无上下文」时 RefinePrompt 省略上下文块（润色仅句式整理）。pbxproj 未动（文件系统同步分组自动纳入 Modules/Context）。
- 2026-08-19：三项改动——① LLM 连接预热：冷连接 TLS 握手吃润色预算（真机首试 1219ms 超 1.2s、重试 1562ms 超 1.5s 连退），新增 `Modules/Refiner/LLMPrewarmer.swift`（`GET {baseURL}/models` 2s 超时、Bearer 鉴权不打响应体、失败静默 DEBUG、在飞防重），关键为 delegate 的 `llmSession` 同时注入 Refiner 与预热器（共享 keep-alive 连接池否则预热无效）；触发点为 `handleHotkeyDown` 起录成功（`prewarmLLM` 可空钩子，菜单路径同覆盖）。② 润色预算放宽（需求 v0.9）：3s（1.2+0.3+1.5）→ 4.3s（2.0+0.3+2.0），原因"响应波动+冷连接致 3s 下回退率过高，润色成功但略慢优于快但未润色"；常量集中在 `PromptRefiner` 三个 timeout。③ 上下文日志补强：无标题两条路径分开（「无辅助功能权限，仅记录 App 名」vs「已授权 AX 但取不到焦点窗口标题」，collector 注入 axTrustedProvider），快照日志补 AppCategory 分类。单测 +9（226 总），build/test 全绿。

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
