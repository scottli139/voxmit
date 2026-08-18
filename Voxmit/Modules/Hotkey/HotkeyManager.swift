import Combine
import CoreGraphics
import Foundation

/// 热键动作（HotkeyManager 输出给 VoicePipeline 的语义事件；
/// §4.2.0：HotkeyManager 只上报原始按下/松开，时序判定集中在 Pipeline）
enum HotkeyAction: Equatable {
    /// 热键按下；associated value = keyDown 瞬间旁路修饰键是否处于按下（FR-D4）
    case hotkeyDown(bypassActive: Bool)
    case hotkeyUp
    /// Esc 按下（FR-B5 取消手势）
    case escape
    /// event tap 被系统禁用（超时/用户输入），需恢复
    case tapDisabled
}

/// 预设热键（FR-B2 的 MVP 版：四档预设即时生效；完整自定义录入留 V1.1）。
/// rawValue 即 keyCode；default 仍为右 Option。
enum HotkeyPreset: Int64, CaseIterable, Sendable {
    case rightOption = 0x3D
    case rightCommand = 0x36
    case rightShift = 0x3C
    case fn = 0x3F // Fn / Globe

    var keyCode: Int64 { rawValue }

    var displayName: String {
        switch self {
        case .rightOption: return "右 Option"
        case .rightCommand: return "右 Command"
        case .rightShift: return "右 Shift"
        case .fn: return "Fn（Globe）"
        }
    }

    /// 该键的 flagsChanged 判定修饰位
    var flag: CGEventFlags {
        // HotkeyEventParser.eventFlag 覆盖全部四档，强制解包安全
        HotkeyEventParser.eventFlag(forModifierKeyCode: Int(keyCode))!
    }

    /// 由 keyCode 解析预设；未知值回退右 Option（设置页只写预设值，此为防御）
    init(keyCode: Int64) {
        self = HotkeyPreset(rawValue: keyCode) ?? .rightOption
    }
}

/// CGEvent 流 → 热键语义事件的纯解析器（§4.2.1）。
/// 无系统依赖，单测直接喂合成事件序列覆盖全部分支。
struct HotkeyEventParser {
    /// Esc 键 keyCode（kVK_Escape）
    static let escapeKeyCode: Int64 = 0x35

    /// 热键 keyCode（默认右 Option 0x3D，读自 hotkey.keyCode 设置）
    var hotkeyKeyCode: Int64
    /// 旁路修饰键对应的 CGEventFlags（默认 Shift，读自 hotkey.bypassModifier 设置）
    var bypassModifierFlag: CGEventFlags

    private(set) var isHotkeyPressed = false

    /// 热键对应的修饰位（检测与对账共用同一来源，保证判定一致；
    /// 默认右 Option → .maskAlternate——左右 Option 合并位，任一 Option 按住均置位）
    var hotkeyFlag: CGEventFlags {
        Self.eventFlag(forModifierKeyCode: Int(hotkeyKeyCode)) ?? .maskAlternate
    }

    /// 修饰键 keyCode → CGEventFlags 映射（仅修饰键有 flagsChanged 按住/松开语义；
    /// 普通组合键的自定义属 FR-B2 完整自定义，V1.1，届时改监听 keyDown）
    static func eventFlag(forModifierKeyCode keyCode: Int) -> CGEventFlags? {
        switch keyCode {
        case 0x38, 0x3C: return .maskShift       // 左/右 Shift
        case 0x3B, 0x3E: return .maskControl     // 左/右 Control
        case 0x3A, 0x3D: return .maskAlternate   // 左/右 Option
        case 0x37, 0x36: return .maskCommand     // 左/右 Command
        case 0x3F: return .maskSecondaryFn       // Fn / Globe
        default: return nil
        }
    }

    mutating func handle(
        eventType: CGEventType,
        keyCode: Int64,
        flags: CGEventFlags
    ) -> HotkeyAction? {
        switch eventType {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            return .tapDisabled
        case .flagsChanged where keyCode == hotkeyKeyCode:
            // 右 Option 判定（§3.4.2）：Alternate 置位 → 按下，清除 → 松开；只在沿变化时产出事件
            let pressed = flags.contains(hotkeyFlag)
            guard pressed != isHotkeyPressed else { return nil }
            isHotkeyPressed = pressed
            // 按住期间其他修饰键变化不影响录音（§3.4.2）；旁路只在 keyDown 瞬间判定（FR-D4）。
            // 热键与旁路同修饰位（如右 Shift 热键 + Shift 旁路）时旁路恒假——
            // 否则 keyDown 恒含该位、每次录音都跳过润色（旁路自定义属 V1.1）
            let bypassActive = hotkeyFlag == bypassModifierFlag
                ? false
                : flags.contains(bypassModifierFlag)
            return pressed ? .hotkeyDown(bypassActive: bypassActive) : .hotkeyUp
        case .keyDown where keyCode == Self.escapeKeyCode:
            return .escape
        default:
            return nil
        }
    }

    /// 状态对账（真机 bug 修复）：keyUp 事件可能丢失（tap 被系统临时禁用、安全输入期、
    /// 其他 App 热键冲突干扰），解析器随后卡在 pressed=true，后续每次按下都被判为重复事件丢弃。
    ///
    /// 保守原则：只纠正"卡死的 pressed=true"——解析器认为按着、真实修饰位已清除时，
    /// 合成一次 hotkeyUp（走正常松手通道，Pipeline 状态机保持一致）；反向不一致
    /// （真实按着而解析器漏了 keyDown）只重置状态、不发事件（避免意外触发录音）。
    ///
    /// maskAlternate 为左右 Option 合并位：flag 已清除 ⇒ 热键必已松开，对账安全。
    mutating func synced(withCurrentFlags flags: CGEventFlags) -> HotkeyAction? {
        let actuallyPressed = flags.contains(hotkeyFlag)
        if isHotkeyPressed, !actuallyPressed {
            isHotkeyPressed = false
            return .hotkeyUp
        }
        if !isHotkeyPressed, actuallyPressed {
            isHotkeyPressed = true // 只重置，不发事件
        }
        return nil
    }
}

/// 全局热键（需求文档 §4.2.1）：CGEventTap **listen-only**（只需"输入监控"权限），
/// 监听 flagsChanged（右 Option 按住/松开）与 keyDown（Esc）。
@MainActor
final class HotkeyManager {
    /// 热键按下；参数 = 旁路修饰键是否处于按下
    var onHotkeyDown: ((Bool) -> Void)?
    var onHotkeyUp: (() -> Void)?
    var onEscape: (() -> Void)?

    private let permissionManager: PermissionManager
    private let defaults: UserDefaults
    private(set) var parser: HotkeyEventParser
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdog: Timer?
    private var permissionCancellable: AnyCancellable?
    private var defaultsObserver: (any NSObjectProtocol)?

    init(permissionManager: PermissionManager, defaults: UserDefaults = .standard) {
        self.permissionManager = permissionManager
        self.defaults = defaults
        self.parser = Self.makeParser(defaults: defaults)

        // 权限驱动启停（§4.4）：无输入监控权限不创建 tap（菜单降级入口可用）；
        // 权限补齐后（PermissionManager refresh 推送快照）动态开启
        permissionCancellable = permissionManager.$snapshot.sink { [weak self] snapshot in
            Task { @MainActor in
                if snapshot.canUseGlobalHotkey {
                    self?.start()
                } else {
                    self?.stop()
                }
            }
        }

        // 热键预设即时生效（FR-B2 的 MVP 版）：hotkey.keyCode 变化时热替换解析参数，
        // tap 事件流不动
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyHotkeyConfiguration() }
        }
    }

    /// 由设置构建解析器（热键预设 + 旁路修饰键；依赖 SettingsKeys.registerDefaults 已注册）
    private static func makeParser(defaults: UserDefaults) -> HotkeyEventParser {
        let preset = defaults.object(forKey: SettingsKeys.hotkeyKeyCode) == nil
            ? HotkeyPreset.rightOption
            : HotkeyPreset(keyCode: Int64(defaults.integer(forKey: SettingsKeys.hotkeyKeyCode)))
        let bypassKeyCode = defaults.integer(forKey: SettingsKeys.hotkeyBypassModifier)
        return HotkeyEventParser(
            hotkeyKeyCode: preset.keyCode,
            bypassModifierFlag: HotkeyEventParser.eventFlag(forModifierKeyCode: bypassKeyCode) ?? .maskShift
        )
    }

    /// 热键切换热替换：仅换解析参数（keyCode/旁路位），tap 事件流不变。
    /// 旧键若仍标记为按下（跨键残留），先合成一次松手让 Pipeline 走正常流程归位，
    /// 再换新解析器（新实例即状态复位，isHotkeyPressed = false）
    private func applyHotkeyConfiguration() {
        let newParser = Self.makeParser(defaults: defaults)
        guard newParser.hotkeyKeyCode != parser.hotkeyKeyCode else { return }
        if parser.isHotkeyPressed {
            onHotkeyUp?()
        }
        AppLog.info(.hotkey, "热键切换：keyCode \(self.parser.hotkeyKeyCode) → \(newParser.hotkeyKeyCode)")
        parser = newParser
    }

    /// 启动监听（幂等；无输入监控权限时不创建 tap）
    func start() {
        guard permissionManager.snapshot.canUseGlobalHotkey else { return }
        setupTap()
        startWatchdog()
    }

    func stop() {
        stopWatchdog()
        teardownTap()
    }

    // MARK: - CGEventTap

    private func setupTap() {
        guard eventTap == nil else { return }
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly, // listen-only：事件放行不拦截，只需"输入监控"权限（§4.2.1）
            eventsOfInterest: mask,
            callback: hotkeyEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            AppLog.error(.hotkey, "CGEventTap 创建失败（输入监控权限缺失？），菜单降级入口可用")
            return // 创建失败（如权限缺失）：保持停止，菜单降级入口可用
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        AppLog.info(.hotkey, "CGEventTap 已创建（热键 keyCode \(self.parser.hotkeyKeyCode)）")
        reconcileHotkeyState() // tap 重建后对账（启动/重建时机）
    }

    private func teardownTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    /// tap 自愈（§4.2.1 健壮性）：被系统禁用则重新 enable；RunLoop source 失效则整体重建；
    /// 末尾对账按键状态（看门狗巡检时机）
    private func ensureTapAlive() {
        guard permissionManager.snapshot.canUseGlobalHotkey else { return }
        if let tap = eventTap, !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        if let source = runLoopSource, !CFRunLoopSourceIsValid(source) {
            teardownTap()
        }
        if eventTap == nil {
            setupTap() // 内部末尾已对账（重建时机）
            return
        }
        reconcileHotkeyState()
    }

    /// 看门狗：source 失效后不再有任何回调，只能周期性巡检（5s 间隔，空闲开销可忽略）
    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ensureTapAlive() }
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    /// 按键状态对账（真机 bug 修复：keyUp 丢失导致解析器卡死 pressed=true）。
    /// 读取修饰键真实状态，只纠正"卡死的 pressed=true"（合成 hotkeyUp 走正常松手通道），
    /// 反向不一致只重置不发事件——判定细节见 HotkeyEventParser.synced 注释。
    ///
    /// 选型：`hidSystemState` 读 HID 层物理修饰键状态，不受其他 App 合成事件影响；
    /// 备选 `.combinedSessionState`（含会话级合成状态），若真机发现误纠正再评估切换。
    private func reconcileHotkeyState() {
        let flags = CGEventSource.flagsState(.hidSystemState)
        if let action = parser.synced(withCurrentFlags: flags), action == .hotkeyUp {
            AppLog.notice(.hotkey, "检测到 keyUp 丢失（按键状态卡死），已合成松手自愈")
            onHotkeyUp?()
        }
    }

    // MARK: - 事件处理

    /// 处理 tap 事件（参数已在 C 回调中提取，CGEvent 非 Sendable 不跨隔离域传递）；
    /// listen-only 不消费事件，由回调原样返回（§4.2.1）
    func handleTapEvent(type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        let action = parser.handle(eventType: type, keyCode: keyCode, flags: flags)
        switch action {
        case .tapDisabled:
            // event tap 被系统禁用（超时/用户输入）：立即恢复 + 巡检重建
            // （ensureTapAlive 末尾对账按键状态——禁用期间可能丢了 keyUp）
            AppLog.notice(.hotkey, "event tap 被系统禁用（\(String(describing: type))），自动恢复")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            ensureTapAlive()
        case .hotkeyDown(let bypassActive):
            onHotkeyDown?(bypassActive)
        case .hotkeyUp:
            onHotkeyUp?()
        case .escape:
            onEscape?()
        case nil:
            break
        }
    }
}

/// CGEventTap 回调（C 约定，不可捕获上下文；经 userInfo 找回实例）。
/// RunLoop source 挂在主 RunLoop，回调在主线程触发，assumeIsolated 安全。
/// manager 由 VoxmitAppDelegate 持有、与 App 同生命周期，passUnretained 不会悬垂。
private func hotkeyEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // listen-only：恒原样放行事件（§4.2.1）
    let passthrough = Unmanaged.passUnretained(event)
    guard let userInfo else {
        return passthrough
    }
    // CGEvent 非 Sendable，keyCode/flags 在回调现场提取后再进入 MainActor 隔离域
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    MainActor.assumeIsolated {
        manager.handleTapEvent(type: type, keyCode: keyCode, flags: flags)
    }
    return passthrough
}
