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

    /// 修饰键 keyCode → CGEventFlags 映射（仅修饰键有 flagsChanged 按住/松开语义；
    /// 普通组合键的自定义属 FR-B2，P1，届时改监听 keyDown）
    static func eventFlag(forModifierKeyCode keyCode: Int) -> CGEventFlags? {
        switch keyCode {
        case 0x38, 0x3C: return .maskShift       // 左/右 Shift
        case 0x3B, 0x3E: return .maskControl     // 左/右 Control
        case 0x3A, 0x3D: return .maskAlternate   // 左/右 Option
        case 0x37, 0x36: return .maskCommand     // 左/右 Command
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
            let pressed = flags.contains(.maskAlternate)
            guard pressed != isHotkeyPressed else { return nil }
            isHotkeyPressed = pressed
            // 按住期间其他修饰键变化不影响录音（§3.4.2）；旁路只在 keyDown 瞬间判定（FR-D4）
            return pressed ? .hotkeyDown(bypassActive: flags.contains(bypassModifierFlag)) : .hotkeyUp
        case .keyDown where keyCode == Self.escapeKeyCode:
            return .escape
        default:
            return nil
        }
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
    private var parser: HotkeyEventParser
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdog: Timer?
    private var permissionCancellable: AnyCancellable?

    init(permissionManager: PermissionManager, defaults: UserDefaults = .standard) {
        self.permissionManager = permissionManager
        // 依赖 SettingsKeys.registerDefaults 已注册（App 启动时），缺省回退右 Option + Shift
        let hotkeyKeyCode = defaults.object(forKey: SettingsKeys.hotkeyKeyCode) == nil
            ? Int64(0x3D)
            : Int64(defaults.integer(forKey: SettingsKeys.hotkeyKeyCode))
        let bypassKeyCode = defaults.integer(forKey: SettingsKeys.hotkeyBypassModifier)
        self.parser = HotkeyEventParser(
            hotkeyKeyCode: hotkeyKeyCode,
            bypassModifierFlag: HotkeyEventParser.eventFlag(forModifierKeyCode: bypassKeyCode) ?? .maskShift
        )

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
            return // 创建失败（如权限缺失）：保持停止，菜单降级入口可用
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
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

    /// tap 自愈（§4.2.1 健壮性）：被系统禁用则重新 enable；RunLoop source 失效则整体重建
    private func ensureTapAlive() {
        guard permissionManager.snapshot.canUseGlobalHotkey else { return }
        if let tap = eventTap, !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        if let source = runLoopSource, !CFRunLoopSourceIsValid(source) {
            teardownTap()
        }
        if eventTap == nil {
            setupTap()
        }
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

    // MARK: - 事件处理

    /// 处理 tap 事件（参数已在 C 回调中提取，CGEvent 非 Sendable 不跨隔离域传递）；
    /// listen-only 不消费事件，由回调原样返回（§4.2.1）
    func handleTapEvent(type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        let action = parser.handle(eventType: type, keyCode: keyCode, flags: flags)
        switch action {
        case .tapDisabled:
            // event tap 被系统禁用（超时/用户输入）：立即恢复 + 巡检重建
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
