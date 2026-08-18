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
