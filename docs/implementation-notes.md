# 实现细节知识库

> 本文件沉淀实现过程中确认的架构要点、API 踩坑与已知问题——即需求文档没写、又值得后来者优先知道的内容。
>
> 写入规则：
> - 每条只写核心约束与结论，附出处；需求文档已有的内容**只放指针、不复制细节**（避免双处维护漂移）；
> - `AGENTS.md` 保持精简，不承载本文档内容；任务进度在 `PLAN.md`。

## 目录

- [已知问题](#已知问题)
- [架构要点](#架构要点)（Phase 1 起逐步补充）
- [评审期已确认的实现要点](#评审期已确认的实现要点)
- [发布流程](#发布流程)（工程建立后补充）
- Git 规范：见 `CONTRIBUTING.md`「Commit 规范」

## 已知问题

### ad-hoc 签名下"辅助功能"授权条目失效（开发构建）

- 现象（2026-08-18 真机首测）：系统设置中 Voxmit 的辅助功能开关已打开，但 `AXIsProcessTrusted()` 持续返回 false，权限自检页仍显示"未授权"（麦克风/输入监控正常翻绿）。
- 原因：开发构建为 ad-hoc 签名，designated requirement 仅 cdhash（`codesign -dr - <app>` 可查），无 Team ID；TCC 辅助功能授权绑定签名身份，此前自动创建/旧构建留下的条目对当前二进制无效——列表里开关显示为开，实为失效条目。
- 应对（实测有效）：系统设置中 "−" 移除 Voxmit → `tccutil reset Accessibility com.voxmit.app` → 手动 "+" 重新添加当前构建并打开开关（必要时重启 App）。
- 开发期注意：重新构建会改变 cdhash，辅助功能授权可能需重做上述步骤；根治靠稳定签名身份——开发期可用 Xcode 登录个人 Apple ID 的 "Apple Development" 证书，发布构建走 Developer ID + 公证（需求文档 §4.4）。
- **2026-08-19 已根治（本机）**：签名改为 xcconfig 分层（`Configurations/Signing.xcconfig` 入库默认 ad-hoc + `LocalSigning.xcconfig` gitignored 覆盖为本机 Developer ID），TCC 授权与 Keychain 信任跨构建持久；切换签名身份后需重做一次性授权（TCC 三项 + Keychain 条目删旧重建）。其他机器无 LocalSigning.xcconfig 时仍按 ad-hoc 构建，本条目上文依旧适用。

### 热键 keyUp 丢失导致永久失效（2026-08-18 已修复）

- **现象**：与其他 App 的热键冲突干扰（真机案例：微信语音输入快捷键）后，右 Option 永久失效（按住不再出现录音 HUD），重启 App 才恢复。
- **根因**：`HotkeyEventParser.isHotkeyPressed` 只在收到该键 flagsChanged 事件时翻转；keyUp 丢失（tap 被系统临时禁用 / 安全输入期 / 他 App 干扰）后解析器永久停在 pressed=true，后续每次按下都被"沿变化"判定为重复事件丢弃；看门狗只查 tap/RunLoop source 活性，不对账按键状态，无法自愈。
- **修复**：parser 新增纯方法 `synced(withCurrentFlags:)`，`HotkeyManager.reconcileHotkeyState()` 在三个时机读真实修饰键状态对账（看门狗巡检 5s / tapDisabled 恢复后 / tap 重建后）；保守原则——只纠正"卡死的 pressed=true"（合成一次 hotkeyUp 走正常松手通道，Pipeline 状态机保持一致），反向不一致（漏 keyDown）只重置状态不发事件（避免意外触发录音）。检测与对账共用 `hotkeyFlag`（keyCode → CGEventFlags 映射）保证判定一致。
- **选型**：`CGEventSource.flagsState(.hidSystemState)` 读 HID 层物理修饰键状态，不受其他 App 合成事件影响；备选 `.combinedSessionState`（含会话级合成状态），若真机发现误纠正再评估切换。注意新版 SDK 中旧函数式 API `CGEventSourceFlagsState(_:)` 已改名 `CGEventSource.flagsState(_:)`。
- **触发场景备忘**：热键冲突干扰、tap 临时禁用（系统负载/超时）、安全输入（密码框聚焦）。

### 模型"已就绪"但永远 Speech 兜底（就绪误判卡死，2026-08-18 已修复）
- **现象**：首次下载（官方端点超时）留下残骸目录后，设置页显示"模型已就绪"，但生效引擎永远是 Speech；第一次修复（≥1 个 `.mlmodelc` 校验）仍不彻底——残骸含部分 `.mlmodelc` 目录包（如只有 MelSpectrogram），照样放行，重启后循环复发（真机日志实锤 `AudioEncoder.mlmodelc` 缺失）。
- **根因链**（三者叠加才成卡死，任一环节单独存在都不致命）：① 就绪校验太弱——校验强度必须与"激活成功的必要条件"对齐（完整产物集，缺一不可）；② `startDownloadIfNeeded()` 幂等 no-op——ready 态把镜像下载永远短路；③ 激活 `loadModels()` 加载残骸失败 → catch 保持 Speech。
- **修复**：`ModelFolderValidator.isReady` 要求完整产物集（`config.json` + `AudioEncoder/MelSpectrogram/TextDecoder.mlmodelc` 三个目录包；whisperkit-coreml 全变体 tiny/small/large-v3 同构，写死）；`markInvalidModel` 自愈链——打回 failed → **每会话自动重试下载一次**（`autoRetryUsed` 会话闸防循环，用尽后停 failed 等手动重试）。**2026-08-18 去删除化**：初版会先删残骸目录强制重下，已撤——激活失败可能是网络/tokenizer 资产缺失等非损坏原因，删目录会毁掉好文件；自实现下载器重试自带完整性校验（完整文件跳过、半截续传、缺文件补齐），无需删除。
- **教训**：幂等短路（ready 不再下载）+ 弱校验 + 静默兜底（catch 只切换不反馈）三者叠加会藏死状态机；兜底路径必须有可见的状态回退出口，且"重试"必须拿到干净的输入（删除坏产物）。

### 设置窗口不置顶（LSUIElement，2026-08-18 已修复）

- **现象**：菜单栏点「设置…」后，设置窗口有时藏在其他窗口后面。
- **根因**：LSUIElement App 打开 SwiftUI Settings 场景时 App 未激活，窗口不获焦点。
- **修法**：`SettingsView.onAppear` 里 `NSApp.activate()`（macOS 14+ API；`activate(ignoringOtherApps:)` 已废弃）。权限自检页（AppKit 手动托管窗口）本就有 `makeKeyAndOrderFront` + `NSApp.activate()`，无此问题。

### Speech 兜底失败：系统级听写关闭（2026-08-18 已修复）

- **现象**：WhisperKit 模型未就绪时由 Speech 兜底，转写失败"Siri and Dictation are disabled"——语音识别权限已授权（authorized），但系统级"听写"被关闭（系统设置 → 键盘 → 听写）。
- **根因**：`SFSpeechRecognizer` 端侧识别依赖系统听写服务；权限矩阵只管 TCC 授权，不管系统级开关。该错误来自运行时 AssistantServices（`kAFAssistantErrorDomain` 系），SDK 无公开错误码（`SFErrors.h` 不含此码）。
- **修复**：`SpeechErrorMapper` 纯函数在识别错误出口映射——错误域含 "Assistant" 且文案含 "Dictation" → `SpeechEngineError.dictationDisabled`，用户可操作文案（HUD failed 态直接指引开启路径）；其余错误原样透传。
- **教训**：兜底引擎的可用性 ≠ 权限授权；系统级服务开关（听写）也是依赖项，错误文案要给用户可操作的出口。

### 模型下载 -997：后台传输服务不可用回退前台（2026-08-18 已修复）

- **现象**：镜像端点下载失败"Lost connection to background transfer service"（NSURLErrorDomain -997 = `NSURLErrorBackgroundSessionWasDisconnected`）——本机 nsurlsessiond 不可用（与 logd 损坏同源的迁移机环境特例）。
- **修复**：下载器端点循环内，单端点先后台 session（`useBackgroundSession: true`），捕获 -997（**按错误码判定，不匹配文案**；SDK 里常量名是 `NSURLErrorBackgroundSessionWasDisconnected`，Swift 侧 `NSURLErrorBackgroundSessionWasDisconnected` / `URLError.Code.backgroundSessionWasDisconnected` 均可用）后同端点前台 session 重试一次，打点注明会话类型；不影响端点间回退顺序；取消不回退。前台 session 的断点续传仍由 incomplete 文件机制保证，跨启动续传不受影响。
- **2026-08-18 已废弃**：随自实现下载器（见下节"模型下载三连根因"）全程前台 session，该回退逻辑已移除；此条留作 -997 判定口径存档。
- **注意**：-997 在这台机器是环境特例（nsurlsessiond 坏）；用户机器上罕见，但回退路径普适。

### Speech 兜底识别中文出英文胡话（locale 与听写语言资产，2026-08-18 已修复）

- **现象**：用户开启听写后说中文，Speech 兜底识别成英文胡话（"Hello hello hello"）——`SFSpeechRecognizer()` 无参初始化用了系统默认（英文）locale。
- **修复**：`SFSpeechRecognizer(locale:)` 取设置键 `asr.speechLocale`（默认 `zh-CN`，本产品主场景中文口述+夹英文术语；WhisperKit 天然中英混识不受此限）；`SpeechLocaleResolver` 纯解析（空/空白回退 zh-CN；有效性由识别器初始化与端侧资产检查兜底）。
- **端侧语言资产依赖**：zh-CN 端侧识别要求系统「听写 → 语言」里已添加中文（资产不在则 `supportsOnDeviceRecognition == false`）。两条边界分别映射可操作文案：`localeUnsupported`（`SFSpeechRecognizer(locale:)` 返回 nil）与 `onDeviceLanguageMissing`（端侧资产缺失）——均指引去 系统设置 → 键盘 → 听写，并注明等 WhisperKit 模型就绪即不受此限。`requiresOnDeviceRecognition = true` 不变（隐私口径：端侧优先，不走 Apple 服务器）。
- **教训**：Speech 兜底三层依赖都要兜底文案——TCC 权限（授权弹窗）、系统听写开关、听写语言资产；locale 不写死英文是默认陷阱。

### HUD 尺寸双重驱动递归栈溢出（2026-08-19 线上崩溃，已修复）

- **崩溃报告要点**：EXC_BAD_ACCESS / "Thread stack size exceeded due to excessive recursion"（主线程栈溢出）；调用栈 `NSHostingView.updateAnimatedWindowSize(_:)` → `windowDidLayout()` → `NSWindow _setFrameCommon:display:` → layout → 回到 `updateAnimatedWindowSize`，循环至栈爆；触发于 HUD 显示多行反馈文案撑大面板后约 40 秒。
- **根因**：HUD 截断修复时给面板**同时**接了两套尺寸驱动——`NSHostingController.sizingOptions = .preferredContentSize`（启用 AppKit 的 `updateAnimatedWindowSize`，自动跟内容动画改窗）+ KVO 订阅 `preferredContentSize` 手动 `setContentSize`。KVO 在 layout 过程中同步触发，同步 `setContentSize` 又在 layout 回调里再开 `setFrameCommon` → 两套互相触发 layout 直至栈爆（0.5pt 容差挡不住 SwiftUI 的动画尺寸调整参与循环）。
- **修复**：① 移除 `sizingOptions`（掐掉 AppKit 自动驱动——递归源）；② resize 一律经主队列**异步合并派发**（连续变化只应用最后一次，`DispatchQueue.main.async` 打断同步递归链）；③ 尺寸计算改为"文案属性变化（阶段/报告/提示条）→ `sizeThatFits` → 同一派发通道"，电平高频不订阅；钳制/容差逻辑保留（HUDLayout 160–420、高度不封顶、0.5pt 容差）。
- **教训**：**layout 回调（KVO/windowDidLayout）里同步改 window frame 就是递归源**——窗口尺寸调整永远异步派发；同一面板的尺寸只能有一条驱动通道，AppKit 自动驱动与手动驱动不可并存。

### WhisperKit 短音频语言误判（自动检测不可靠 → 锁 zh，2026-08-19 已修复）

- **现象**：2 秒中文"喂喂喂123123"被识别为英文 "We we we year three year three"——未指定语言时 Whisper 自动检测，短而重复的音节极易误判。
- **修复**：`kit.transcribe(audioArray:decodeOptions:)` 传 `DecodingOptions(language:)`，取设置键 `asr.whisperLanguage`（默认 `"zh"` 锁中文，`"auto"` 恢复自动检测）；`WhisperLanguageResolver` 纯解析。
- **API 结论（包源码核实）**：`DecodingOptions.language: String?`（Configurations.swift:159），取 ISO 639-1 码（"zh"/"en"/"ja"…），`Constants.languageCodes` 为合法集（"chinese"/"mandarin" 亦映射到 "zh"）；nil = 自动检测（`options.language == nil` 走检测分支，TextDecoder.swift:998）。
- **注意**：锁中文后中英文混识不受影响（纯英文音频仍转英文，只是检测不再摇摆）；转写日志已补 `language=` 字段供识别质量排查。

### Keychain 反复弹授权窗：ad-hoc 签名 ACL 不信任（2026-08-19 已缓解）

- **现象**：润色一次连弹 4 次钥匙串密码窗，启动也弹 4 次；且因弹窗阻塞（Keychain 同步读无法响应取消），润色 1.2s 尝试预算被拖到 ~4s，日志表现为 `timeout`。
- **根因**：ad-hoc 签名的 cdhash 随每次构建变化，macOS 无法用 designated requirement 表达「信任此 app」，「始终允许」无法持久化；securityd 对不可信调用方一次 SecItem 调用也可能连弹多个授权窗。一次润色有 3 次读 Key（refiner 守卫 + 两次 attempt 内 client），启动时设置快照日志再读 1 次，各自弹窗。
- **缓解**（KeychainHelper 内存缓存，NSLock 串行化首次读取）：会话内只真实读一次 Keychain，弹窗合并到启动期（启动的设置快照日志即触发），润色 3s 预算内零 Keychain 阻塞；读/写/删均同步缓存。
- **同一构建内零弹窗的办法**：删除旧构建创建的条目（`security delete-generic-password -s com.voxmit.app -a llm-api-key`）后由当前构建重新保存（SecItemAdd 的创建者天然被信任；SecItemUpdate 只改数据不改 ACL，所以必须删了重建）。
- **根治**：稳定签名身份——本机 2026-08-19 起以 Developer ID 本地签名（xcconfig 分层机制，见「ad-hoc 签名下"辅助功能"授权条目失效」条目），授权一次跨构建持久；无本地覆盖的 ad-hoc 构建每次重新部署后最多容忍一次弹窗。

### macOS 26：Developer ID + hardened runtime + 未公证 → 麦克风授权静默拒绝（2026-08-19 已修复）

- **现象**：Developer ID 签名部署后，麦克风点「请求授权」直接变「已拒绝」；系统设置麦克风列表始终不出现 Voxmit；TCC 用户库无任何麦克风条目（决策根本没走到记录层）。输入监控 / 辅助功能不受影响。
- **探针隔离矩阵**（最小 MicProbe.app，同二进制同 bundle id，仅签名不同）：
  - ad-hoc：弹窗 → 允许 → authorized；
  - Developer ID + `--options runtime`（hardened runtime）：无弹窗秒拒、TCC 无记录；
  - Developer ID 不加 runtime：弹窗 → 允许 → authorized。
- **结论**：macOS 26（26.6 beta 实测）把「hardened runtime + Developer ID + 无公证票据」按待分发产物处理，麦克风类敏感权限静默拒绝；ad-hoc 与「Developer ID 无 runtime」按本地开发放行。
- **修复**：签名 xcconfig 分层中，入库默认 `ENABLE_HARDENED_RUNTIME = YES`（ad-hoc 无影响、Release 公证分发需要），本机 `LocalSigning.xcconfig` 覆盖 `ENABLE_HARDENED_RUNTIME[config=Debug] = NO`；Release 分发构建保持开启且必须走 Apple 公证。
- **排除过的嫌疑**：Xcode 自动注入的 Debug 测试 entitlements（`temporary-exception.mach-lookup` / `get-task-allow` 等）——清空后 hardened runtime 下依旧拒绝，与 entitlements 无关；`tccutil reset` / 删除条目重建也无效（问题不在 TCC 记录层）。

## 架构要点

### 权限自检（Phase 1，FR-G5）

- 系统权限 API 收敛在 `PermissionChecking` 协议（`SystemPermissionChecker` 实现）之后，`PermissionManager` 依赖协议注入；降级决策（`canRecord` / `canUseGlobalHotkey` / `injectionCapability` / `requiredGranted` / `allGranted`）全部收敛在纯值类型 `PermissionSnapshot` 上，单测零系统依赖。
- 系统设置深链（macOS 26.6 实测有效）：`x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` / `?Privacy_ListenEvent` / `?Privacy_Accessibility`。
  - 验证方法：`open <url>` 后 `log stream --predicate 'process == "SecurityPrivacyExtension"'` 可见「隐私与安全性」扩展启动；pane id 路由已证实（旧式 `com.apple.preference.security` 被解析到 `com.apple.settings.PrivacySecurity.extension`）。
  - 局限：锚点落到**具体子页面**（麦克风/输入监控/辅助功能列表页）未能从 shell 程序化证实——该构建机无屏幕录制权限（截屏全黑）、无可用辅助功能访问（System Events 枚举任何 App 窗口恒为 0）；各锚点打开了对应 TCC 服务列表的加载（`kTCCServiceMicrophone` 等），但扩展会同时预加载多个服务列表，信号非锚点独有。首次真机验收时肉眼确认一次即可。
- 菜单栏 App 的首启自动弹窗：MenuBarExtra content 在菜单首次打开时才实例化；SwiftUI `Window` Scene 的 `defaultLaunchBehavior(.suppressed)` 需 macOS 15+（工程部署目标 14.0）——因此引导窗口走 AppKit 手动托管（`PermissionOnboardingWindowController` + `NSHostingController`），经 `@NSApplicationDelegateAdaptor` 在 `applicationDidFinishLaunching` 判定后弹出；窗口关闭用 `NSWindow.willCloseNotification` 释放引用（避开 NSWindowDelegate 的并发隔离标注差异）。
- `@NSApplicationDelegateAdaptor` 要求 delegate 同时遵守 `ObservableObject`；`@MainActor` 类的存储属性默认值可直接调用 `@MainActor` 初始化器（SE-0411 isolated default values）。
- Combine 接线坑：`@Published private(set)` 的 `$` 投影对外只读，`publisher.assign(to: &obj.$prop)` 跨类型编译失败（`cannot pass immutable value as inout argument`）；改为 `sink` + 内部方法（`VoicePipeline.applyPermissionSnapshot`）。
- 单测以 App 为宿主（TEST_HOST）：`applicationDidFinishLaunching` 在测试运行时会真实执行，需用 `ProcessInfo.environment["XCTestConfigurationFilePath"]` 守卫，跳过引导弹窗与权限接线，保证测试不依赖真实权限状态。

### 热键与状态机（Phase 2，FR-B1/B5）

- 状态机时钟注入：`PipelineClock` 协议（`now` + `sleep(for:)`，取消时必须抛 CancellationError）；生产用 `SystemPipelineClock`，单测用 `MockClock` 虚拟时间（`advance(by:)` 唤醒到期 continuation；`withTaskCancellationHandler` 的 `onCancel` 里立即以 CancellationError 唤醒，保证 Esc 取消不依赖时钟推进）。**关键坑**：① sleep 的截止时间必须锚定在事件发生的绝对时刻（Pipeline 里 `remaining = 阈值 - (now - keyDown)`），否则"任务被调度晚于 advance"的竞态让截止点漂到未来；② 协议的非隔离异步方法（transcribe 等）跑在协作线程池而非主 Actor——mock 的可变状态会被主线程（advance/cancel 的 onCancel）与池线程（sleep 注册）并发访问，**必须加锁**（曾因裸字典踩踏 SIGSEGV：cancel 持 Swift 任务状态锁回调 onCancel → removeValue 撞上池线程注册）；注册与 isCancelled 检查须在同一把锁内、resume 在锁外，配合 removeValue 返回nil 保证单次 resume；③ Date 以 2001 纪元存储秒数，大基数下 Double 误差 ~1e-7，"恰好 300ms"的边界断言不可行，用 ±1ms 逼近锁定阈值语义；④ 等待异步链路完成用"主 Actor 探针×N"（`await Task { @MainActor in }.value`，FIFO 保证此前入队工作已执行，链路的每次池跳需一个探针轮次），不用定长 sleep。
- 录音起点语义（§4.3 易误读）：keyDown **立即** `audio.start()` + 快照目标（避免吞掉开头百毫秒语音），200ms 确认期通过才进入公开的 `.recording`；300ms 误触判定**从进入 recording 起算**；确认期内松开"整次忽略"（静默丢弃，无状态变化），与 Esc 取消（有 `.cancelled` 闪现）区分。
- 终止态（`.injected` / `.failed` / `.cancelled`）当前**即刻回 idle**（同一同步流程内两次赋值，测试经 Combine 历史可观测）；HUD 反馈与停留时长属 Phase 4，届时再引入停留。
- §9.1 三个异步协议（`TranscriptionEngine` / `PromptRefining` / `TextInjecting`）已加 `Sendable` 约束：@MainActor 的 Pipeline 跨隔离域调用其非隔离异步方法，Swift 6 下非 Sendable 直接编译错误；实现方（WhisperKit 引擎等）需保持 Sendable。
- CGEventTap 回调与严格并发：`CGEvent` 非 Sendable，**不能**捕获进 `MainActor.assumeIsolated` 闭包——在 C 回调现场提取 `keyCode` / `flags` 标量后再入隔离域；`Unmanaged.passUnretained(self)` 供 userInfo 回取（manager 与 App 同生命周期，无悬垂风险）。
- 事件解析与系统交互分离：`HotkeyEventParser` 纯值类型（keyCode/flags → `HotkeyAction`，含"只在沿变化产出事件""按住期间其他修饰键不影响""keyDown 瞬间判定旁路"），单测直接喂合成事件；`HotkeyManager` 只剩 tap 生命周期，不进单测（真机验收）。
- tap 自愈（§4.2.1）：回调内收到 `tapDisabledByTimeout/UserInput` 立即 `CGEvent.tapEnable`；RunLoop source 失效后不会再有回调，另加 5s 看门狗 Timer 巡检（`CGEvent.tapIsEnabled` / `CFRunLoopSourceIsValid`，失效整体重建）。
- 权限驱动启停：HotkeyManager 订阅 `PermissionManager.$snapshot`，`canUseGlobalHotkey` 变化即 start/stop——权限补齐后热键自动生效，撤销后自动停止（菜单降级入口接管）。
- 环境坑（本机）：DerivedData 在外置盘上，一旦有测试失败，Swift Testing 的进程内符号化（CoreSymbolication 逐个读二进制）会卡数分钟呈"假死"状（sample 可见 `issueRecorded → CSSymbolicatorCreate…`）；排查时先让输出可流式观察：`script -q /dev/null xcodebuild test …`（分配 pty，行缓冲；注意只能整条命令后台化使用，前台直接跑会因当前 shell 无 tty 报 `tcgetattr: Operation not supported`）。
- 预设热键热替换（FR-B2 的 MVP 版，2026-08-18）：`HotkeyPreset` 四档（rawValue=keyCode）；Fn/Globe 0x3F → `.maskSecondaryFn`；HotkeyManager 监听 `UserDefaults.didChangeNotification`（自定义 suite 的 set 也会发，object 为该实例）重建 parser，tap 事件流不动；切换时旧键 pressed 残留先合成一次 hotkeyUp 让 Pipeline 归位，再换新 parser（新实例即状态复位）；热键与旁路同修饰位时（右 Shift 热键 + Shift 旁路）旁路判定恒假，否则 keyDown 恒含该位、每次录音都跳过润色。
- Fn 键注意：系统设置「按下 Fn 键以…」若绑定切换输入法等动作，系统行为与我们的监听并存（预期单击 Fn 仍产 flagsChanged；听写为双击手势不冲突）——真机验收确认。

### 音频采集（Phase 3，FR-A1/A2/A3）

- AudioCapture 线程模型：`start/stop/cancel` 与 engine 重建约定主线程（`dispatchPrecondition` 断言；Pipeline 是 @MainActor 天然满足）；tap 回调在实时音频线程，只做"重采样 → 短临界区加锁追加 → 电平发布"；样本缓冲用 NSLock 保护（音频线程追加、主线程读取清空）。`levels`/`events`（PassthroughSubject）从音频/看门狗线程发布，订阅者自行 `receive(on:)`（Phase 4 HUD 注意）。
- AVAudioConverter 流式重采样：单块输入用"consumed 标志 + 二次索取返回 `.noDataNow`"的 input block 模式；**SRC 启动延迟实测缺口 ~176–240 帧（≈11–15ms @16kHz），恒定不随流增长**，秒级录音可忽略，无需 flush；注意输出侧状态枚举没有 `.noDataNow`（那是输入侧 `AVAudioConverterInputStatus`）。
- 输入设备应用链路：设置存 UID（`audio.inputDeviceUID`）→ `AVCaptureDevice.DiscoverySession`（`.microphone` + `.external`，**枚举不需要麦克风权限**）列出可用设备 → 纯函数 `InputDeviceResolver` 决策回落 → CoreAudio `kAudioHardwarePropertyDevices` 遍历 + `kAudioDevicePropertyDeviceUID` 匹配翻译成 `AudioDeviceID`（返回 CF 对象是 +1 持有，`takeRetainedValue` 平衡）→ `AudioUnitSetProperty(inputNode.audioUnit, kAudioOutputUnitProperty_CurrentDevice, …)` 在 engine.start 前应用；`inputNode.audioUnit` 是 Optional。
- 静音前缀裁剪工程值（§4.2.2 蓝牙麦协商延迟场景）：10ms 帧峰值检测，阈值 **-45 dBFS**（≈ 振幅 0.0056；高于常见底噪 -60dB 以下、远低于说话电平 -20dB 上下），命中后保留 **50ms** 前导防切辅音起音；全静音 → 空数组，上游按"空音频"静默结束（§4.2.3）。
- MaxDurationWatchdog 独立组件（limit + PipelineClock 注入）：计时**锚定 `start()` 调用时刻**（`remaining = limit - (now - startedAt)`），否则"任务首次调度晚于时钟推进"的竞态让截止点漂移（同 Phase 2 状态机确认期结论）；回调在协作线程池触发，接收方自行切主线程。
- 设备热切换：`.AVAudioEngineConfigurationChange` 通知（queue: .main）→ teardown + beginCapture 重建续录，`samples` 缓冲不动（已录保留）；重建失败（如设备全拔光）发 `.captureInterrupted` 事件；指定设备断开由 resolver 判定回落并发 `.inputDeviceFellBackToDefault`（提示 UI 均待 Phase 4）。

### 录音 HUD（Phase 4）

- 非激活面板硬要求的落法：`NSPanel` + `.nonactivatingPanel` + `ignoresMouseEvents = true` + `orderFront` 显示（**不** `makeKey`/`NSApp.activate`——焦点必须留在目标 App；权限引导窗才用 activate）；`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` 全屏/多 Space 可见；位置 = `NSScreen.main.visibleFrame` 底部居中（visibleFrame 已避开 Dock）。
- 状态机与 HUD 的职责切分：终止态（injected/failed/cancelled）在状态机里**即刻回 idle 不变**；停留时长（成功 0.8s / 未润色 1.2s / 手动粘贴 2.5s / 失败 2.5s）由 HUD 侧 `HUDVisibility` 纯函数决策 + Controller 用 PipelineClock 调度隐藏。**两处必须对"终止态后紧跟的 idle"去抖**：Controller 已有 hideTask 时忽略该 idle；ViewModel 锁存终止态展示（`phase.isTerminalFeedback`），否则成功对勾会被 idle 瞬间清空——这是本轮实测抓到的真 bug。
- 反馈态数据源：Pipeline 的 `lastInjectionReport: InjectionReport?`（outcome 档位 + wasRefined），在 finish 前赋值（Combine 时序保证 .injected 到达时已可见）；keyDown 清空。"未润色"角标 = injected 且 wasRefined == false（覆盖润色回退与 FR-D4 旁路两种路径）。
- ViewModel 订阅 `audioCapture.levels`（音频线程发布）必须 `receive(on: DispatchQueue.main)`；Combine sink 进 @MainActor 用 `MainActor.assumeIsolated`（发射源均在主线程，安全）。

### 本地转写（Phase 5，FR-C1）

- **WhisperKit 0.18 API 要点**（读包源码核实，勿凭记忆）：`WhisperKit(_ config:) async throws` + `loadModels()`；转写 `transcribe(audioArray: [Float], decodeOptions:) async throws -> [TranscriptionResult]`（输入即 16kHz Float，正好对接 AudioCapture 产出）；落盘目录约定 `downloadBase/models/argmaxinc/whisperkit-coreml/openai_whisper-<variant>`。**2026-08-18 决策反转：弃用 `WhisperKit.download`，改自实现 `ModelRepoDownloader`**（根因见"模型下载三连根因"节）——此前"不重复造轮子"的依据（断点续传/进度/多文件快照官方维护）在镜像网络下失效（metadata 校验死 + tokenizer 独立联网），自实现后这两块全部可控；激活时 `WhisperKitConfig(downloadBase:modelFolder:)` 显式锚定 Models 目录（tokenizer 搜索路径）。
- 落盘校验分层：下载返回目录存在性（管理器）+ `loadModels()` 成功（引擎激活）兜底；不做逐文件哈希。
- **Swift 6 并发坑两则**：① @MainActor 类不能直接遵守继承了 Sendable 的协议（"conformance crosses into main actor-isolated code"）——Router 这类需要跨域读的持有器改非隔离类 + NSLock（写主线程断言、读任意线程）；② `@Sendable` 闭包参数仍须显式 `@escaping`（函数型参数默认非逃逸）。
- Speech 兜底引擎引入**第四个 TCC 权限**（语音识别，`NSSpeechRecognitionUsageDescription` 已入 Info.plist）：`SFSpeechRecognizer.authorizationStatus()` notDetermined 时才请求；`requiresOnDeviceRecognition = true` 前查 `supportsOnDeviceRecognition`；识别回调可能多次返回，continuation 需单次 resume 保护 + 取消时映射 CancellationError（Pipeline 的 Esc 路径期望它）。
- 占位注入改 `PlaceholderClipboardInjector`（仅写剪贴板返回 `.clipboardOnly`）：让转写文字在 Phase 6/8 之前即可手动粘贴使用；NSPasteboard 约定主线程访问（协议非隔离 async 会跳池线程，须 `await MainActor.run`）。
- **HF 端点回退（2026-08-18 真机）**：huggingface.co 在国内网络不可达（curl 000）；`WhisperKit.download(variant:…, endpoint:)` 支持自定义端点（HubApi 构造参数 endpoint，另支持 `HF_ENDPOINT` 环境变量），无需 fork。落地：官方 → hf-mirror.com 自动回退（`asr.modelRepoEndpoint` 键：unset/auto=回退链，huggingface/hf-mirror=强制，无设置页 UI）；取消（CancellationError）不回退。断点续传跨端点有效：incomplete 文件按**本地目标路径**记录（与域名无关）。端点链机制沿用至自实现下载器；下载执行本体已替换（见下节）。

### 模型下载三连根因与自实现下载器（2026-08-18 已修复）

- **根因一：metadata 校验死**。swift-transformers `HubApi.getFileMetadata` 从 HEAD 响应取 `X-Linked-Size ?? Content-Length` 作 size，缺则抛 `invalidMetadataError`（无文件名、不可定位）。hf-mirror 的 resolve-cache 对非 LFS 小文件的 HEAD **经常性缺 Content-Length**（实测 config.json 必现 size=nil）→ 小文件必挂、大文件（302 绝对重定向头部齐全）正常，整体确定性失败。官方站无 resolve-cache 层无此问题，但本网络被墙不可用。
- **根因二：tokenizer 独立网络依赖**。`WhisperKit.loadModels()` → `loadTokenizerIfNeeded()` 需 tokenizer 文件（tokenizer.json + tokenizer_config.json，属另一仓库 `openai/whisper-<variant>`），本地找不到就联网下载——被墙环境激活必挂。已验证的离线解法：两文件放进模型目录根（`openai_whisper-small/`），`additionalSearchPaths` 含 modelFolder 命中后完全离线（真机验证：ANE 编译 104s 后激活成功）。
- **根因三（设计失误，已撤）**：markInvalidModel 初版会删除变体目录——激活失败可能是网络原因，删目录毁掉 484MB 好文件。
- **自实现下载器**（`Modules/Transcription/ModelRepoDownloader.swift` + `URLSessionRepoHTTPClient.swift`）：tree API 拿清单（`GET <endpoint>/api/models/<repo>/tree/main/<variant>?recursive=true`，大小取 size 字段）；逐文件 `GET <endpoint>/<repo>/resolve/main/<path>`（`.partial` + `Range: bytes=N-` 续传 + 完成校验 + 原子移动，**不依赖 HEAD**）；tokenizer 同法下载 `openai/whisper-<variant>` 两文件放模型目录根；单文件失败重试 2 次（退避 1s/3s，PipelineClock 注入）；取消抛 CancellationError 不重试。幂等重入：完整文件跳过（原子移动落盘即完整）、完整 partial 直接移动（崩在移动前的恢复）、半截 partial 续传。进度聚合 `DownloadProgressTracker`：总字节随响应动态回填（镜像小文件无大小属正常）。可观测性：清单/每文件完成（名+大小+耗时）/失败原因均带端点打点。
- **教训**：依赖的"隐形网络面"要全部摸清（模型 + tokenizer 是两个仓库）；上游库的环境假设（HEAD 头部齐全）在你的目标网络（镜像 cache 层）不成立时，果断自实现——决策反转不可耻，诊断可见性是底线。

### 上下文快照（Phase 7，FR-E1/FR-F5）

- **NSWorkspace 并发标注坑**：`NSWorkspace.shared` 在 macOS 26 SDK 为 @MainActor 标注，非隔离协议方法（`ContextCollecting.snapshotTarget`）里直接访问会编译报错——在 `NSWorkspaceSystem.frontmostApp()` 内用 `MainActor.assumeIsolated` 收敛（调用方均为 @MainActor：Pipeline 与单测），协议保持非隔离不动。
- **AX 焦点窗口标题**：`AXUIElementCreateApplication(pid)` → `kAXFocusedWindowAttribute` → `kAXTitleAttribute`；进函数先查 `AXIsProcessTrusted()`，无权限直接 nil（§4.2.5 降级为"仅 App 名"，与无焦点窗口同一路径，不区分提示文案——用户引导统一走权限自检页）。
- **松手校验语义（§3.4.3）**：`handleHotkeyUp` **必须**重新快照（不能只回读 keyDown 快照）：录音中 Cmd+Tab 切前台是真实场景；bundleID 或 pid 不同 → NOTICE 打点并以松手时前台为准（注入目标 + 润色上下文）。`targetSnapshot` 随之更新为松手快照。
- **两条无标题路径要分开打**：无辅助功能权限（`axTrustedProvider()==false` →「无辅助功能权限，仅记录 App 名」）与已授权但取不到焦点窗口（→「已授权 AX 但取不到焦点窗口标题」）——排障时两种根因完全不同（前者去开权限，后者是窗口系统状态）；快照日志均带 AppCategory 分类（校验分类表正确性）。
- **「无上下文」模式**：前台取不到时 TargetSnapshot 为 pid 0 + 空标识；`RefinePrompt.userMessage` 对空 appName 省略整个【上下文】块（§4.2.5：润色仅做句式整理），避免向 LLM 发送"当前 App：（）"的畸形上下文。
- **AppCategoryMapper 纯表定位**：分类表放 Context 模块但由 Pipeline 直接调用（纯函数无需 mock），不进 `ContextCollecting` 协议（协议不膨胀）；AI CLI 无独立 bundleID，归宿主终端分类（注入适配 Phase 8 复用此表）。

### 结果注入（Phase 8，FR-F1/FR-F4/FR-F5）

- **NSPasteboard 主线程访问**：`TextInjecting.inject` 是非隔离 async（协作线程池执行），NSPasteboard 约定主线程——`SystemPasteboardManager` 全部方法 `await MainActor.run`（沿用 Phase 5 占位注入的教训，见本地转写节）。
- **剪贴板快照/恢复**：`pasteboardItems`（nullable，Swift 侧 `[NSPasteboardItem]?`，SDK 头文件确认）快照后 `writeObjects(items)` 恢复；`clearContents` 不会使已保存的 NSPasteboardItem 失效（对象独立于 pasteboard）。
- **changeCount 竞争保护（§4.2.6）**：capture 存 items，write 返回写入后的 changeCount，restore 前比对当前 changeCount——不等（用户复制了新内容）则放弃恢复并丢弃快照，绝不覆盖用户新内容。注意比对的是 write 后的 changeCount（非 capture 的），因为 write 会使 changeCount +1。
- **降级语义关键**：`clipboardOnly` 档只 write、**不 capture 不 restore**——文本必须留在剪贴板供手动 Cmd+V，若恢复原剪贴板会导致用户粘贴失败。这与完整流程的"恢复"语义相反，容易写错。
- **CGEvent 模拟按键需辅助功能权限**（非输入监控，§4.4 误区）：`CGEventPost` 无权限时静默失败不报错，故注入前必须 `AXIsProcessTrusted()` 预检，失败直接降级仅剪贴板（不做无效 Cmd+V）。Cmd+V = virtualKey 0x09 + `.maskCommand`；Return = 0x24；source 用 `.combinedSessionState`，post 到 `.cghidEventTap`，keyDown+keyUp 成对发。
- **模拟按键重入 event tap 回调崩溃（2026-08-19 真机 SIGSEGV，两次复现）**：`CGEventPost` 模拟按键的事件会经 RunLoop source 投递回 HotkeyManager 的 listen-only tap（mask 含 keyDown + flagsChanged），回调 `hotkeyEventTapCallback` 里 `MainActor.assumeIsolated` 在该重入路径下"当前执行器"校验访问野指针 → `swift_task_isMainExecutorImpl` → `swift_getObjectType` 崩溃（EXC_BAD_ACCESS）。**初版只过滤 `keyDown && keyCode != Esc` 不够**（第二次仍崩，触发事件是 flagsChanged），**彻底修法：回调里完全弃用 `MainActor.assumeIsolated`，改 `Task { @MainActor in … }` 标准派发**（回调即刻返回放行，事件处理异步执行，主 actor 串行队列保证按下/松开顺序不变）。教训：`assumeIsolated` 的"假设当前是主 actor"在 RunLoop 回调 + 合成事件重入时不可靠，事件 tap 回调一律走 `Task { @MainActor }` 而非 assumeIsolated；listen-only 回调还要按事件类型最小过滤（非 Esc 的 keyDown 直接放行）。
- **取消分支的剪贴板恢复**：注入器内 sleep 被取消（Esc）时仍要尽力 restore（剪贴板已写入新文本，不恢复会污染用户剪贴板），但跳过 autoSend（Return）；`TextInjecting.inject` 签名不 throws，取消由上层 Pipeline 的 `Task.checkCancellation()` 收尾，注入器吞掉 sleep 的 CancellationError 返回即可。
- **换行折叠（§4.2.6）**：仅 terminal 目标且 `inject.collapseNewlines` 开启时折叠；折叠 = `\r\n`/`\n`/`\r` 全部替换为单个空格（不压缩其他空白，忠实原文，防止英文多空格语义变化）。决策在 `InjectionAdapter`（纯逻辑可单测），分类复用 `AppCategoryMapper`。
- **「目标不可注入」的检测边界（P0）**：仅做 AX 权限 + pid != 0 + bundleID 非空三条件；"目标 App 注入瞬间退出"的竞态 CGEventPost 无返回值无法可靠检测（事件发到届时前台 App），列入真机验证项而非代码兜底。

### Prompt 润色（Phase 6，FR-D1/FR-D4）

- **预算分配（v0.10 二次放宽）**：§4.2.4 总预算 3s→4.3s→7.3s（3.5+0.3+3.5）。第二次放宽的实测依据（本机 curl api.moonshot.cn）：DNS 0.66s、TCP 1.30s、TLS 握手 2.3~2.7s、冷连接 chat 3.8~5.0s、热连接纯服务端处理 1.2~2.9s——冷连接首试 3.5s 内握手完成并入池，重试走热连接 2.9s < 3.5s 兜底成功。机制不变：`withThrowingTaskGroup` 竞速，常量集中在 `PromptRefiner.firstAttemptTimeout/retryBackoff/retryAttemptTimeout`。
- **LLM 连接预热（2026-08-19）**：冷连接 TLS 握手会吃掉首试预算——录音开始（`handleHotkeyDown` 成功起录后，含菜单降级路径）以 fire-and-forget 发 `GET {baseURL}/models`（8s 超时、Bearer 鉴权、不打响应体、失败静默 DEBUG）。**关键是与 Refiner 共享同一 URLSession 实例**（delegate 的 `llmSession`，独立 keep-alive 连接池），否则连接池不共享、预热无效；在飞防重复发，每次新录音可再预热（连接可能已被服务端关闭）。预热不进 Pipeline 状态机（`prewarmLLM` 可空钩子注入）。**教训：预热超时必须大于 TLS 握手时间**——实测握手 2.3~2.7s，初版取 2s 导致预热从未成功、形同虚设（日志实证每次超时），后提至 8s（录音一般 3~10s，窗口够握手完成）。
- **隐私门为什么挡在"首次实际发送前"**：`llm.refineEnabled` 默认 true，用户可能不进设置页就直接使用——在 App 启动或开关打开时弹窗都为时过早且无感，唯一可靠拦截点是"第一次真正要发送转写文本"。实现：`llm.privacyAcknowledged` 键 + PromptRefiner 注入 `@Sendable () async -> Bool` 门（AppDelegate 弹 NSAlert，「继续」记键、「本次跳过」返回 false 下次再问）；未配 Key 或开关关闭时门根本不被调用。LSUIElement 弹窗先 `NSApp.activate()`（同设置窗口置顶坑）。
- **LLM 客户端**：`ChatCompleting: Sendable` 协议隔离（单测 mock）；`OpenAIChatClient.makeRequest/parseContent` 静态纯函数可单测；错误只分 missingAPIKey / httpStatus(code) / invalidResponse——**日志只落错误类别与耗时，不落 Key 与转写/润色文本本体**（隐私红线）；请求体 max_tokens=500（§4.2.4 成本约束），**不携带 temperature**——Kimi Code 端点仅允许 temperature=1（其他值 400，2026-08-19 踩坑），省略时各服务商走默认（Moonshot 0.3），兼容性最好；httpStatus 错误携带服务端响应体摘录（≤500 字符；错误体为 {"error":{...}} 元信息，不含请求文本本体，是 4xx/5xx 排障关键）。
- **UTF-8 安全截断**：选区 ≤2KB 按字节截断后回退到最近完整字符边界（`String(bytes:encoding:)` 返回 nil 即断点，逐字节回退），不产 U+FFFD 替换符；加省略号标识截断。
- **消息组装**：system 用 §9.1 模板原文；user = 【上下文】（App 名+bundleID、窗口标题、选区≤2KB）+【口述内容】原文；旁路（FR-D4）在状态机层跳过润色（wasRefined=false → HUD「未润色」角标）。
- **端点选型实测（2026-08-19）**：Kimi Code 端点（`api.kimi.com/coding/v1`，会员额度）结构性不适合润色后端——仅允许 temperature=1；强制思考且 reasoning 计入 max_tokens（500 额度被思考吃光 → 正文空串，表现为「请求成功但无内容」）；延迟 3~6.6s（highspeed 档 hello 0.96s 但真实负载仍 3s+）装不进 3s 预算。Moonshot 开放平台（`api.moonshot.cn`，按量付费）`moonshot-v1-8k`：0.6~2s、无强制思考、工程口述质量达标（指代消解/术语保留/分点），为 §8-1 默认值的实测背书；诗歌等离域输入会被强行「工程化」——v0.11 模板加"非工程口述只做通顺化、上下文仅供消歧"硬约束后修复（真机实证旧模板会把 Notes 窗口标题脑补成操作指令）。真机验收：首试 1.2s 超时（冷连接握手占大头）→ 重试成功（连接复用），端到端 3.3s——连接预热/预算再平衡列后续优化项。
- **terminal 窗口标题省略 + 模板二次加固（v0.12，2026-08-19 真机反馈）**：口述"可以了，提交吧"在 Terminal 目标下被润色成"提高 Terminal 窗口的显示效果"——terminal 窗口标题（进程名/TMPDIR/尺寸等）噪声大、指代价值低，却诱导 LLM 把上下文当操作对象脑补。修法双管齐下：① `RefinePrompt.userMessage` 对 `appCategory == .terminal` 省略窗口标题（只保留 App 名）；② system prompt 6 条→7 条加硬约束（输出必须与口述表达同一件事、口述里没有的对象/动作/步骤一律不得出现、短促对话/流程用语按字面通顺化不扩展）。教训：光靠模板约束的边际效益递减，**从输入侧切除噪声上下文**（terminal 标题）比再加一条模板约束更有效。

### 日志设施（2026-08-18，产品级）

**用法**：打点一律走门面 `AppLog.info(.pipeline, "…")`（级别方法 + category 枚举），不要再新建 `Logger` 实例；门面同时写 os_log 与内存环形缓冲（`LogRingBuffer`，容量 2000，本次会话保底诊断）。

**级别约定**（与 os_log 对齐）：

| 级别 | 用途 |
|---|---|
| debug | 高频/进度类（电平、下载进度百分比等；默认不落诊断重点） |
| info | 关键生命周期事件（录音开始/结束、转写完成、模型就绪、引擎切换、导出成功） |
| notice | 降级/权限缺失等用户可感知但不致命（权限快照变化、设备回落、自愈、授权结果） |
| error | 失败路径（下载失败、转写失败、注入失败、tap 创建失败） |
| fault | 不应发生的不变量破坏 |

**隐私红线**：禁止记录 API Key 等凭据；禁止记录转写文本/润色内容/剪贴板内容本体（只可记长度、耗时、成败）；音频数据只记时长/样本数；上下文快照默认记 App 名/bundleID，窗口标题只记长度或脱敏（可能含文件名/账号）。门面统一以 `privacy: .public` 写 os_log（允许入场的内容本就限为非敏感元数据），调用点无需再标注 privacy。

**打点原则**：状态机转换、外部交互（网络/权限/系统 API）成败、用户操作（热键、设置变更）三类必须有；进度/电平等高频事件只允许 debug；每行日志应能独立读懂（带状态名/引擎名/端点/耗时 ms 等关键上下文）。

**诊断导出**（设置页「诊断」区「导出诊断日志…」）：文件 = 环境头（App 版本/build、macOS、机型、关键设置快照、四项权限状态，不含凭据）+ 系统日志段（OSLogStore `.system` scope + subsystem 谓词，口径最近 24h 含历史进程）+ 本次会话内存缓冲段；每行格式 `时间 级别 [category] 消息`。**OSLogStore 实测结论（本机 macOS 26.6，环境特例）**：`.system` 与 `local()` 抛"invalid log archive"（internalCode 6）、`.currentProcessIdentifier` 抛 nilError——本机 logd 持久存储不可用（`log show` 同样报此错，仅 `log stream` 实时可用）；用户正常机器上 OSLogStore 可用，失败时导出自动降级为仅内存缓冲段并注明。`OSLogStore.local()` 文档注明需管理员账户，故不走该入口。

**日志文件落盘**（2026-08-18，参照 DDFileLogger 思路自实现，无第三方依赖）：门面三路同写（os_log / 环形缓冲 / 文件，调用点不变）。路径 `~/Library/Application Support/Voxmit/Logs/voxmit-yyyy-MM-dd.log` 按日命名追加写；全部级别（含 debug）都落文件——用户无法改级别，现场分析需要。`LogFileStore`：所有 IO 在专用串行队列（utility QoS）异步执行，任意线程可写不阻塞主线程；写盘失败熔断降级（本会话停止文件写入，os_log/缓冲不受影响）；保留最近 7 个文件且总量 ≤ 20MB（启动与跨天滚动时清理；当天文件无条件保留；非 `voxmit-*.log` 命名的外来文件不参与清理）；每次启动写分隔行（版本/build/macOS）。测试宿主（TEST_HOST）不写盘，保持单测零磁盘副作用；`LogFileStore` 单测走临时目录 + MockClock（注意 append 异步入队，跨天用例需先 flush 再推进时钟；createFile 不自建父目录）。

**排查命令**：`log show --predicate 'subsystem == "com.voxmit.app"' --last 1h`；实时 `log stream --predicate 'subsystem == "com.voxmit.app"'`；Console.app 过滤 subsystem。

## 评审期已确认的实现要点

> 2026-08-17 文档评审（v0.2）沉淀；细节均在需求文档对应小节，此处仅作速查指针：

- CGEventTap 权限分工：listen-only 监听 = **输入监控**；`CGEventPost` 模拟按键 = **辅助功能**，两者不可互替 → 需求文档 §4.4
- 右 Option 判定：`flagsChanged` + keyCode `0x3D` + `.maskAlternate` 置位/清除 → §4.2.1
- event tap 被系统禁用（`tapDisabledByTimeout` / `tapDisabledByUserInput`）必须监听并 `CGEvent.tapEnable` 恢复 → §4.2.1
- 安全输入（密码框聚焦）期间热键被系统阻断，属正常行为：不报错、不绕过 → §4.2.1
- 注入目标：keyDown 快照 + 松手校验；本工具全程非激活（`LSUIElement` + `.nonactivatingPanel`）→ §3.4.3
- AX 写入用 `kAXSelectedTextAttribute`（光标处插入），**禁止** `AXValue`（会覆盖已有输入）→ §4.2.6
- 剪贴板恢复前查 `changeCount`，被用户新内容覆盖则放弃恢复 → §4.2.6
- CLI 目标默认折叠换行为空格，防多行文本被逐行提交 → §4.2.6
- 转写默认 WhisperKit small（~500MB）+ Speech 兜底；Intel 引导云端 ASR → §4.2.3
- 润色 3s 总超时 + 1 次快速重试 + 回退原文（带 `refined` 标记供角标）→ §4.2.4
- 交互手感参考豆包桌面版：实时波形 + "松手发送，按 Esc 取消" → §7

## 发布流程

（工程建立后补充：Developer ID 签名 → `notarytool` 公证 → `stapler` 钉票 → DMG；要求见需求文档 §4.4）
