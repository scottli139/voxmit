import CoreGraphics
import Foundation
import Testing
@testable import Voxmit

/// HotkeyEventParser：CGEvent 流 → 热键语义事件的纯解析（需求文档 §4.2.1 / §3.4.2）。
/// 合成事件序列驱动，零系统权限依赖。
struct HotkeyEventParserTests {

    private let rightOption: Int64 = 0x3D

    private func makeParser() -> HotkeyEventParser {
        HotkeyEventParser(hotkeyKeyCode: rightOption, bypassModifierFlag: .maskShift)
    }

    @Test func rightOption_flagsChanged_downThenUp_emitsEdges() {
        var parser = makeParser()

        let down = parser.handle(eventType: .flagsChanged, keyCode: rightOption, flags: [.maskAlternate])
        #expect(down == .hotkeyDown(bypassActive: false))

        let up = parser.handle(eventType: .flagsChanged, keyCode: rightOption, flags: [])
        #expect(up == .hotkeyUp)
    }

    @Test func duplicateDown_withoutEdgeChange_suppressed() {
        var parser = makeParser()

        _ = parser.handle(eventType: .flagsChanged, keyCode: rightOption, flags: [.maskAlternate])
        // 热键仍按住时再次收到同 keyCode 的 flagsChanged（如系统重复/其他修饰键联动）：不重复产出
        let again = parser.handle(eventType: .flagsChanged, keyCode: rightOption, flags: [.maskAlternate])

        #expect(again == nil)
        #expect(parser.isHotkeyPressed)
    }

    @Test func shiftHeldAtKeyDown_bypassActiveTrue() {
        var parser = makeParser()

        // FR-D4：keyDown 瞬间 Shift 处于按下 → 本次跳过润色
        let down = parser.handle(
            eventType: .flagsChanged,
            keyCode: rightOption,
            flags: [.maskAlternate, .maskShift]
        )

        #expect(down == .hotkeyDown(bypassActive: true))
    }

    @Test func otherModifiersChangedWhileHolding_doesNotAffectHotkeyState() {
        var parser = makeParser()
        _ = parser.handle(eventType: .flagsChanged, keyCode: rightOption, flags: [.maskAlternate])

        // 按住期间 Shift 按下/松开（§3.4.2：不影响录音状态）
        let shiftDown = parser.handle(eventType: .flagsChanged, keyCode: 0x38, flags: [.maskAlternate, .maskShift])
        let shiftUp = parser.handle(eventType: .flagsChanged, keyCode: 0x38, flags: [.maskAlternate])
        #expect(shiftDown == nil)
        #expect(shiftUp == nil)
        #expect(parser.isHotkeyPressed)

        // 松开右 Option 时 Shift 恰好也按着：仍正确产出 keyUp
        let up = parser.handle(eventType: .flagsChanged, keyCode: rightOption, flags: [.maskShift])
        #expect(up == .hotkeyUp)
    }

    @Test func escapeKeyDown_emitsEscape() {
        var parser = makeParser()

        let esc = parser.handle(eventType: .keyDown, keyCode: HotkeyEventParser.escapeKeyCode, flags: [])
        #expect(esc == .escape)

        // 其他键的 keyDown 不产生事件
        let a = parser.handle(eventType: .keyDown, keyCode: 0x00, flags: [])
        #expect(a == nil)
    }

    @Test func tapDisabledTypes_emitTapDisabled() {
        var parser = makeParser()

        #expect(parser.handle(eventType: .tapDisabledByTimeout, keyCode: 0, flags: []) == .tapDisabled)
        #expect(parser.handle(eventType: .tapDisabledByUserInput, keyCode: 0, flags: []) == .tapDisabled)
    }

    @Test func eventFlagMapping_modifierKeyCodes() {
        #expect(HotkeyEventParser.eventFlag(forModifierKeyCode: 0x38) == .maskShift)
        #expect(HotkeyEventParser.eventFlag(forModifierKeyCode: 0x3C) == .maskShift)
        #expect(HotkeyEventParser.eventFlag(forModifierKeyCode: 0x3B) == .maskControl)
        #expect(HotkeyEventParser.eventFlag(forModifierKeyCode: 0x3A) == .maskAlternate)
        #expect(HotkeyEventParser.eventFlag(forModifierKeyCode: 0x3D) == .maskAlternate)
        #expect(HotkeyEventParser.eventFlag(forModifierKeyCode: 0x37) == .maskCommand)
        #expect(HotkeyEventParser.eventFlag(forModifierKeyCode: 0x36) == .maskCommand)
        #expect(HotkeyEventParser.eventFlag(forModifierKeyCode: 0x3F) == .maskSecondaryFn)
        #expect(HotkeyEventParser.eventFlag(forModifierKeyCode: 0x00) == nil) // 非修饰键无映射
    }

    // MARK: - 状态对账（keyUp 丢失自愈，真机 bug 修复）

    @Test func synced_stuckPressedWithFlagReleased_synthesizesHotkeyUpAndRecovers() {
        var parser = makeParser()
        _ = parser.handle(eventType: .flagsChanged, keyCode: rightOption, flags: [.maskAlternate])
        #expect(parser.isHotkeyPressed)

        // keyUp 丢失后真实已松开：对账合成 hotkeyUp（走正常松手通道）
        let action = parser.synced(withCurrentFlags: [])
        #expect(action == .hotkeyUp)
        #expect(!parser.isHotkeyPressed)

        // 自愈后：后续正常按下可再次触发 hotkeyDown（修复前会永久判重丢弃）
        let down = parser.handle(eventType: .flagsChanged, keyCode: rightOption, flags: [.maskAlternate])
        #expect(down == .hotkeyDown(bypassActive: false))
    }

    @Test func synced_noMismatch_producesNoEvent() {
        var parser = makeParser()

        // 一致：未按且真实未按
        #expect(parser.synced(withCurrentFlags: []) == nil)

        // 一致：按着且真实仍按着（含另一 Option 也按着的合并位场景）
        _ = parser.handle(eventType: .flagsChanged, keyCode: rightOption, flags: [.maskAlternate])
        #expect(parser.synced(withCurrentFlags: [.maskAlternate]) == nil)
        #expect(parser.isHotkeyPressed)
    }

    @Test func synced_reverseMismatch_resetsSilentlyWithoutEvent() {
        var parser = makeParser()

        // 反向不一致：真实按着但解析器漏了 keyDown → 只重置状态，绝不合成 hotkeyDown
        let action = parser.synced(withCurrentFlags: [.maskAlternate])
        #expect(action == nil)
        #expect(parser.isHotkeyPressed)

        // 重置后真实松开：正常沿事件恢复产出 hotkeyUp
        let up = parser.handle(eventType: .flagsChanged, keyCode: rightOption, flags: [])
        #expect(up == .hotkeyUp)
    }

    @Test func synced_afterTapDisabled_recoversStuckState() {
        var parser = makeParser()
        _ = parser.handle(eventType: .flagsChanged, keyCode: rightOption, flags: [.maskAlternate])

        // tap 被禁用（期间 keyUp 丢失）：tapDisabled 事件不改按键状态
        #expect(parser.handle(eventType: .tapDisabledByTimeout, keyCode: 0, flags: []) == .tapDisabled)
        #expect(parser.isHotkeyPressed)

        // 恢复后对账：真实已松开 → 合成 hotkeyUp，状态归位
        #expect(parser.synced(withCurrentFlags: []) == .hotkeyUp)
        #expect(!parser.isHotkeyPressed)
    }

    // MARK: - 预设热键（FR-B2 的 MVP 版）

    @Test func preset_keyCodeLookupFallbackAndFlagConsistency() {
        #expect(HotkeyPreset(keyCode: 0x3D) == .rightOption)
        #expect(HotkeyPreset(keyCode: 0x36) == .rightCommand)
        #expect(HotkeyPreset(keyCode: 0x3C) == .rightShift)
        #expect(HotkeyPreset(keyCode: 0x3F) == .fn)
        #expect(HotkeyPreset(keyCode: 0x00) == .rightOption) // 未知值回退默认

        // 每档预设的修饰位与解析器映射一致（含 Fn 的 maskSecondaryFn）
        for preset in HotkeyPreset.allCases {
            #expect(HotkeyEventParser.eventFlag(forModifierKeyCode: Int(preset.keyCode)) == preset.flag)
            #expect(!preset.displayName.isEmpty)
        }
    }

    @Test func fnHotkey_flagsChanged_downThenUp() {
        var parser = HotkeyEventParser(hotkeyKeyCode: 0x3F, bypassModifierFlag: .maskShift)

        let down = parser.handle(eventType: .flagsChanged, keyCode: 0x3F, flags: [.maskSecondaryFn])
        #expect(down == .hotkeyDown(bypassActive: false))

        let up = parser.handle(eventType: .flagsChanged, keyCode: 0x3F, flags: [])
        #expect(up == .hotkeyUp)
    }

    @Test func rightCommandHotkey_shiftBypassStillWorks() {
        var parser = HotkeyEventParser(hotkeyKeyCode: 0x36, bypassModifierFlag: .maskShift)

        // 右 Command 与 Shift 不同位：旁路判定不受影响
        let plain = parser.handle(eventType: .flagsChanged, keyCode: 0x36, flags: [.maskCommand])
        #expect(plain == .hotkeyDown(bypassActive: false))
        _ = parser.handle(eventType: .flagsChanged, keyCode: 0x36, flags: [])

        let bypass = parser.handle(eventType: .flagsChanged, keyCode: 0x36, flags: [.maskCommand, .maskShift])
        #expect(bypass == .hotkeyDown(bypassActive: true))
    }

    @Test func rightShiftHotkey_bypassAlwaysDisabled() {
        // 热键为右 Shift 时 keyDown 恒含 maskShift：旁路判定禁用，否则每次录音都跳过润色
        var parser = HotkeyEventParser(hotkeyKeyCode: 0x3C, bypassModifierFlag: .maskShift)

        let down = parser.handle(eventType: .flagsChanged, keyCode: 0x3C, flags: [.maskShift])
        #expect(down == .hotkeyDown(bypassActive: false))

        let up = parser.handle(eventType: .flagsChanged, keyCode: 0x3C, flags: [])
        #expect(up == .hotkeyUp)
    }
}

/// HotkeyManager 热键热替换（FR-B2 预设版）：mock 权限（不建真实 tap）+ 独立 UserDefaults
@MainActor
struct HotkeyManagerTests {

    private func settle() async {
        for _ in 0..<12 {
            await Task { @MainActor in }.value
        }
    }

    @Test func switchHotkey_releasesResidueAndReconfigures() async throws {
        let suiteName = "com.voxmit.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        SettingsKeys.registerDefaults(in: defaults)

        let checker = MockPermissionChecker()
        checker.listenEventGranted = false // 无输入监控权限：start() 不创建真实 tap
        let manager = HotkeyManager(
            permissionManager: PermissionManager(checker: checker),
            defaults: defaults
        )

        var downs: [Bool] = []
        var ups = 0
        manager.onHotkeyDown = { downs.append($0) }
        manager.onHotkeyUp = { ups += 1 }

        // 旧键（右 Option）按下，parser 处于 pressed
        manager.handleTapEvent(type: .flagsChanged, keyCode: 0x3D, flags: [.maskAlternate])
        #expect(downs == [false])
        #expect(manager.parser.isHotkeyPressed)

        // 设置页改热键为右 Command → UserDefaults.didChangeNotification → 热替换
        defaults.set(0x36, forKey: SettingsKeys.hotkeyKeyCode)
        await settle()

        #expect(manager.parser.hotkeyKeyCode == 0x36)
        #expect(!manager.parser.isHotkeyPressed) // 无跨键残留
        #expect(ups == 1)                        // 残留松手已合成（Pipeline 归位）

        // 新键判定即时生效
        manager.handleTapEvent(type: .flagsChanged, keyCode: 0x36, flags: [.maskCommand])
        #expect(downs.count == 2)
        // 旧键事件不再产出
        _ = manager.handleTapEvent(type: .flagsChanged, keyCode: 0x36, flags: [])
        manager.handleTapEvent(type: .flagsChanged, keyCode: 0x3D, flags: [.maskAlternate])
        #expect(downs.count == 2)
    }

    @Test func switchHotkey_sameKeyCode_noOp() async throws {
        let suiteName = "com.voxmit.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        SettingsKeys.registerDefaults(in: defaults)

        let checker = MockPermissionChecker()
        checker.listenEventGranted = false
        let manager = HotkeyManager(
            permissionManager: PermissionManager(checker: checker),
            defaults: defaults
        )
        var ups = 0
        manager.onHotkeyUp = { ups += 1 }

        // 无关设置项变化 / 相同 keyCode：不重建、不合成事件
        defaults.set(false, forKey: SettingsKeys.injectAutoSend)
        defaults.set(0x3D, forKey: SettingsKeys.hotkeyKeyCode)
        await settle()

        #expect(manager.parser.hotkeyKeyCode == 0x3D)
        #expect(ups == 0)
    }

    @Test func unknownStoredKeyCode_fallsBackToRightOption() async throws {
        let suiteName = "com.voxmit.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        SettingsKeys.registerDefaults(in: defaults)
        defaults.set(0x00, forKey: SettingsKeys.hotkeyKeyCode) // 非法值

        let checker = MockPermissionChecker()
        checker.listenEventGranted = false
        let manager = HotkeyManager(
            permissionManager: PermissionManager(checker: checker),
            defaults: defaults
        )

        #expect(manager.parser.hotkeyKeyCode == HotkeyPreset.rightOption.keyCode)
    }
}
