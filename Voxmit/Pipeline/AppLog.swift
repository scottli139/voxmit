import Foundation
import os

/// 日志级别（与 os.Logger 对齐；规范见 docs/implementation-notes.md「日志设施」）
enum AppLogLevel: String, Sendable, CaseIterable {
    case debug   // 高频/进度类
    case info    // 关键生命周期事件
    case notice  // 降级/权限缺失等用户可感知但不致命
    case error   // 失败路径
    case fault   // 不应发生的不变量破坏

    var label: String { rawValue.uppercased() }
}

/// 日志 category（按模块分）
enum AppLogCategory: String, Sendable, CaseIterable {
    case app, hotkey, audio, pipeline, transcription, download, injection, hud, settings, permissions
}

/// 内存环形日志缓冲：当前会话的保底诊断数据（系统日志库不可用时导出仍有内容）。
/// 线程安全（NSLock；打点可能发生在任意线程，如音频实时线程）。
final class LogRingBuffer: @unchecked Sendable {
    struct Entry: Sendable, Equatable {
        let date: Date
        let level: AppLogLevel
        let category: String
        let message: String
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let capacity: Int

    init(capacity: Int = 2000) {
        self.capacity = capacity
    }

    func append(date: Date, level: AppLogLevel, category: String, message: String) {
        lock.withLock {
            entries.append(Entry(date: date, level: level, category: category, message: message))
            if entries.count > capacity {
                entries.removeFirst(entries.count - capacity)
            }
        }
    }

    var snapshot: [Entry] {
        lock.withLock { entries }
    }
}

/// 统一日志入口：写入 os_log（Console.app / log show）+ 内存环形缓冲（诊断导出保底）。
/// 打点：`AppLog.info(.pipeline, "…")`；字符串内容公开记录（不允许凭据/文本本体，见规范）。
enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.voxmit.app"
    private static let ring = LogRingBuffer()

    /// 文件通道：测试宿主（TEST_HOST）不写盘（保持单测零磁盘副作用）；写盘失败内部熔断降级
    private static let fileStore: LogFileStore? = {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return nil }
        return LogFileStore()
    }()

    private static let loggers: [AppLogCategory: Logger] = {
        var map: [AppLogCategory: Logger] = [:]
        for category in AppLogCategory.allCases {
            map[category] = Logger(subsystem: subsystem, category: category.rawValue)
        }
        return map
    }()

    /// 本次会话的内存缓冲（诊断导出用；单测可读）
    static var recentEntries: [LogRingBuffer.Entry] {
        ring.snapshot
    }

    static func debug(_ category: AppLogCategory, _ message: @autoclosure () -> String) {
        log(.debug, category, message())
    }

    static func info(_ category: AppLogCategory, _ message: @autoclosure () -> String) {
        log(.info, category, message())
    }

    static func notice(_ category: AppLogCategory, _ message: @autoclosure () -> String) {
        log(.notice, category, message())
    }

    static func error(_ category: AppLogCategory, _ message: @autoclosure () -> String) {
        log(.error, category, message())
    }

    static func fault(_ category: AppLogCategory, _ message: @autoclosure () -> String) {
        log(.fault, category, message())
    }

    private static func log(
        _ level: AppLogLevel,
        _ category: AppLogCategory,
        _ message: String
    ) {
        let now = Date()
        ring.append(date: now, level: level, category: category.rawValue, message: message)
        if let logger = loggers[category] {
            // 打点内容一律公开（规范禁止凭据/内容本体入场，见 implementation-notes）
            switch level {
            case .debug: logger.debug("\(message, privacy: .public)")
            case .info: logger.info("\(message, privacy: .public)")
            case .notice: logger.notice("\(message, privacy: .public)")
            case .error: logger.error("\(message, privacy: .public)")
            case .fault: logger.fault("\(message, privacy: .public)")
            }
        }
        // 文件通道：行格式与诊断导出一致（DiagnosticLogFormatter）
        fileStore?.append(line: DiagnosticLogFormatter.formatEntry(
            date: now, level: level, category: category.rawValue, message: message
        ))
    }
}
