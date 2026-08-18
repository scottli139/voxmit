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
        #expect(HotkeyEventParser.eventFlag(forModifierKeyCode: 0x00) == nil) // 非修饰键无映射
    }
}
