import AppKit
import CoreGraphics
import Foundation

/// 剪贴板系统抽象（P0）：快照/写入/条件恢复。用于 mock，隔离 NSPasteboard。
/// @MainActor：NSPasteboard 约定主线程访问；方法同步执行，注入链全程主线程无执行器 hop。
@MainActor
protocol PasteboardManaging: Sendable {
    /// 快照当前剪贴板内容（保存 items 供恢复），返回当前 changeCount
    func capture() -> Int
    /// 写入文本，返回写入后的 changeCount；nil = 写入失败
    func write(text: String) -> Int?
    /// 若当前 changeCount == expected 则恢复快照内容；否则放弃（用户复制了新内容）。返回是否执行了恢复
    func restore(ifChangeCountEquals expected: Int) -> Bool
}

/// 模拟按键系统抽象（P0）：Cmd+V 粘贴与 Return 回车。用于 mock，隔离 CGEvent。
/// @MainActor：CGEvent 合成在注入链主线程执行，无 hop。
@MainActor
protocol KeyEventPosting: Sendable {
    func postPaste()
    func postReturn()
}

/// 注入链延迟抽象（@MainActor）：sleep 全程主线程（DispatchQueue.main 定时），
/// 替代 PipelineClock 的 nonisolated sleep——@MainActor 上下文 await nonisolated async
/// 会跨执行器 hop，偶发丢 continuation（真机 bug，见 docs/implementation-notes.md）。
@MainActor
protocol InjectorDelaying: Sendable {
    /// 睡眠指定时长；正常睡满返回 true，任务被取消返回 false（吞掉取消）
    func sleep(for interval: TimeInterval) async -> Bool
}

/// 结果注入 P0 实装（需求文档 §4.2.6 / FR-F1 / FR-F4）：
/// 剪贴板快照 → 写入文本 → 模拟 Cmd+V → 约 300ms 后按 changeCount 竞争保护恢复原剪贴板；
/// 无辅助功能权限 / 无有效目标时降级为仅写剪贴板（不恢复）；
/// autoSend 开启时粘贴后约 150ms 模拟 Return（FR-F4）。
/// 换行折叠决策收敛在 InjectionAdapter（纯逻辑可单测）。
/// 全程 @MainActor：pasteboard/key/delay 均为 @MainActor，零跨执行器 hop。
@MainActor
struct ClipboardInjector: TextInjecting {
    private let pasteboard: any PasteboardManaging
    private let keyPoster: any KeyEventPosting
    private let delayer: any InjectorDelaying
    private let axTrustedProvider: @Sendable () -> Bool
    private let collapseNewlinesProvider: @Sendable () -> Bool

    init(
        pasteboard: any PasteboardManaging,
        keyPoster: any KeyEventPosting,
        delayer: any InjectorDelaying,
        axTrustedProvider: @escaping @Sendable () -> Bool,
        collapseNewlinesProvider: @escaping @Sendable () -> Bool
    ) {
        self.pasteboard = pasteboard
        self.keyPoster = keyPoster
        self.delayer = delayer
        self.axTrustedProvider = axTrustedProvider
        self.collapseNewlinesProvider = collapseNewlinesProvider
    }

    func inject(text: String, into target: TargetSnapshot, autoSend: Bool) async -> InjectionOutcome {
        // 1. 换行折叠（终端目标默认开启；设置/分类决策在 InjectionAdapter）
        let category = AppCategoryMapper.category(for: target.bundleID)
        let shouldCollapse = InjectionAdapter.shouldCollapseNewlines(
            category: category,
            settingEnabled: collapseNewlinesProvider()
        )
        let finalText = shouldCollapse ? InjectionAdapter.collapseNewlines(text) : text

        // 2. 降级判定：无 AX 权限 / 无有效目标 → 仅写剪贴板（文本留存供手动 Cmd+V，不恢复）
        guard axTrustedProvider(), target.pid != 0, !target.bundleID.isEmpty else {
            guard pasteboard.write(text: finalText) != nil else {
                return .failed("剪贴板写入失败")
            }
            AppLog.notice(.injection, "降级为仅剪贴板（clipboardOnly 档，\(finalText.count) 字）：无辅助功能权限或注入目标无效")
            return .clipboardOnly
        }

        // 3. 完整流程：快照 → 写入 → Cmd+V
        let originalChangeCount = pasteboard.capture()
        guard let afterWrite = pasteboard.write(text: finalText) else {
            return .failed("剪贴板写入失败")
        }
        AppLog.debug(.injection, "剪贴板快照 changeCount \(originalChangeCount) → 写入后 \(afterWrite)")
        keyPoster.postPaste()
        AppLog.info(.injection, "已模拟 Cmd+V 至 \(target.appName)（\(finalText.count) 字）")

        // 4. 约 300ms 后恢复剪贴板；取消分支也要尽力 restore（避免污染用户剪贴板）
        let slept = await delayer.sleep(for: 0.3)
        let restored = pasteboard.restore(ifChangeCountEquals: afterWrite)
        if restored {
            AppLog.debug(.injection, "已恢复原剪贴板（changeCount \(afterWrite) 未变）")
        } else {
            AppLog.notice(.injection, "检测到剪贴板被用户改写（changeCount ≠ \(afterWrite)），放弃恢复")
        }

        // 5. autoSend：粘贴后约 150ms 模拟 Return（FR-F4）；首次睡眠被取消则跳过
        if autoSend && slept {
            let secondSlept = await delayer.sleep(for: 0.15)
            if secondSlept {
                keyPoster.postReturn()
                AppLog.info(.injection, "已模拟 Return 自动发送（FR-F4）")
            }
        }

        return .pasted
    }
}

/// 真实剪贴板系统服务（NSPasteboard 约定主线程访问；@MainActor 同步实现）
@MainActor
final class SystemPasteboardManager: PasteboardManaging {
    private var capturedItems: [NSPasteboardItem]?

    func capture() -> Int {
        capturedItems = NSPasteboard.general.pasteboardItems ?? []
        return NSPasteboard.general.changeCount
    }

    func write(text: String) -> Int? {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else { return nil }
        return NSPasteboard.general.changeCount
    }

    func restore(ifChangeCountEquals expected: Int) -> Bool {
        guard let items = capturedItems else { return false }
        guard NSPasteboard.general.changeCount == expected else {
            capturedItems = nil
            return false
        }
        NSPasteboard.general.clearContents()
        let ok = NSPasteboard.general.writeObjects(items)
        capturedItems = nil
        return ok
    }
}

/// 真实模拟按键系统服务（CGEvent 合成 Cmd+V / Return；@MainActor 同步实现）
@MainActor
struct SystemKeyEventPoster: KeyEventPosting {
    func postPaste() {
        Self.postKey(code: 0x09, flags: .maskCommand) // kVK_ANSI_V
    }

    func postReturn() {
        Self.postKey(code: 0x24, flags: []) // kVK_Return
    }

    private static func postKey(code: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }
}

/// 真实注入延迟（@MainActor）：DispatchQueue.main 定时，全程主线程无执行器 hop。
/// 用 `withCheckedThrowingContinuation`（body 同步执行、resume 由主线程定时/取消触发）
/// 而非 `Task.sleep`——后者是 nonisolated async，在 @MainActor 上下文 await 会跨执行器 hop。
@MainActor
struct MainActorInjectorDelayer: InjectorDelaying {
    func sleep(for interval: TimeInterval) async -> Bool {
        // 引用类型持有 continuation，供定时回调与取消回调竞争单次 resume
        final class ContinuationBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _continuation: CheckedContinuation<Void, Error>?

            var continuation: CheckedContinuation<Void, Error>? {
                get { lock.withLock { _continuation } }
                set { lock.withLock { _continuation = newValue } }
            }

            /// 原子取出并清空，保证定时/取消只 resume 一次
            func take() -> CheckedContinuation<Void, Error>? {
                lock.withLock {
                    let c = _continuation
                    _continuation = nil
                    return c
                }
            }
        }

        let box = ContinuationBox()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    box.continuation = continuation
                    DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
                        box.take()?.resume()
                    }
                }
            } onCancel: {
                box.take()?.resume(throwing: CancellationError())
            }
            return true
        } catch {
            return false
        }
    }
}
