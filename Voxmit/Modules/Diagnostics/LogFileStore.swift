import Foundation
import os

/// 日志文件保留策略（纯逻辑可单测；参照 DDFileLogger 思路自实现，不引第三方依赖）：
/// 最多保留最近 N 个日志文件且总量 ≤ 上限；当天文件即使超限也保留（不删正在写入的文件）
enum LogRetentionPolicy {
    static let keepLatestCount = 7
    static let maxTotalBytes: UInt64 = 20 * 1024 * 1024 // 20MB

    /// 应删除的文件：按日期新到旧保前 keepLatest 个且累计不超 maxTotalBytes
    static func filesToDelete(
        _ files: [LogFileInfo],
        keepLatest: Int = keepLatestCount,
        maxTotalBytes: UInt64 = Self.maxTotalBytes
    ) -> [URL] {
        let sorted = files.sorted {
            if $0.day != $1.day { return $0.day > $1.day }
            return $0.url.lastPathComponent > $1.url.lastPathComponent
        }
        var kept = 0
        var runningTotal: UInt64 = 0
        var result: [URL] = []
        for (index, file) in sorted.enumerated() {
            let mustKeep = index == 0 // 最新（当天）文件无条件保留
            let withinCount = kept < keepLatest
            let withinSize = runningTotal + file.size <= maxTotalBytes
            if mustKeep || (withinCount && withinSize) {
                kept += 1
                runningTotal += file.size
            } else {
                result.append(file.url)
            }
        }
        return result
    }
}

/// 日志文件信息（保留策略输入）
struct LogFileInfo: Equatable, Sendable {
    let url: URL
    let day: Date
    let size: UInt64
}

/// 日志文件命名与解析（纯逻辑）：voxmit-yyyy-MM-dd.log
enum LogFileNaming {
    static let prefix = "voxmit-"
    static let suffix = ".log"

    static func fileName(for date: Date) -> String {
        "\(prefix)\(dayString(date))\(suffix)"
    }

    /// 解析文件名中的日期；不符合命名约定返回 nil（外来文件不参与保留清理）
    static func day(of fileName: String) -> Date? {
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(suffix) else { return nil }
        let middle = String(fileName.dropFirst(prefix.count).dropLast(suffix.count))
        return dayFormatter().date(from: middle)
    }

    static func dayString(_ date: Date) -> String {
        dayFormatter().string(from: date)
    }

    private static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

/// 日志文件存储：追加写、按日滚动、启动清理。
///
/// 线程模型：所有文件操作在专用串行队列（utility QoS）执行，append 任意线程可调用、
/// 不阻塞调用方（queue.async）。写盘失败熔断降级（disabled=true 后本会话不再尝试，
/// os_log 与内存缓冲不受影响）——日志 IO 绝不影响主链路。
final class LogFileStore: @unchecked Sendable {
    /// 默认目录：~/Library/Application Support/Voxmit/Logs（与 Models 同根；
    /// 与 VoxmitAppDelegate.modelsDirectory 同源约定）
    static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Voxmit/Logs", directoryHint: .isDirectory)
    }

    /// 自举错误只写 os_log（不回写文件/缓冲，防递归）
    private static let selfLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.voxmit.app",
        category: "logging"
    )

    private let directory: URL
    private let clock: any PipelineClock
    private let keepLatest: Int
    private let maxTotalBytes: UInt64
    private let queue = DispatchQueue(label: "com.voxmit.app.log-file", qos: .utility)

    // 以下状态仅在串行队列上访问
    private var currentHandle: FileHandle?
    private var currentDay = ""
    private var disabled = false
    private var failureCount = 0

    init(
        directory: URL? = nil,
        clock: any PipelineClock = SystemPipelineClock(),
        keepLatest: Int = LogRetentionPolicy.keepLatestCount,
        maxTotalBytes: UInt64 = LogRetentionPolicy.maxTotalBytes
    ) {
        self.directory = directory ?? Self.defaultDirectory
        self.clock = clock
        self.keepLatest = keepLatest
        self.maxTotalBytes = maxTotalBytes
        queue.async { self.startupHousekeeping() }
    }

    /// 追加一行（任意线程，不阻塞；行格式与诊断导出一致）
    func append(line: String) {
        queue.async { self.appendOnQueue(line) }
    }

    /// 排空队列（单测同步用）
    func flush() {
        queue.sync {}
    }

    /// 失败次数（单测断言降级路径用）
    var failureCountForTesting: Int {
        queue.sync { failureCount }
    }

    // MARK: - 队列内实现

    private func startupHousekeeping() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            markFailure("日志目录创建失败：\(error.localizedDescription)")
            return
        }
        cleanupOldFiles()
        // 启动分隔行（便于按会话分段阅读）
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知"
        let macOS = ProcessInfo.processInfo.operatingSystemVersionString
        appendOnQueue("========== App 启动，版本 \(version)（build \(build)），\(macOS) ==========")
    }

    private func appendOnQueue(_ line: String) {
        guard !disabled else { return }
        do {
            try ensureCurrentFile()
            guard let handle = currentHandle else { return }
            try handle.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            markFailure("日志写入失败：\(error.localizedDescription)")
        }
    }

    /// 确保当天文件已打开；跨天滚动时关闭旧文件、建新文件并触发保留清理
    private func ensureCurrentFile() throws {
        let today = LogFileNaming.dayString(clock.now)
        if today == currentDay, currentHandle != nil { return }

        try currentHandle?.close()
        currentHandle = nil
        currentDay = today

        let fileURL = directory.appending(path: LogFileNaming.fileName(for: clock.now))
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            cleanupOldFiles() // 新文件出现后才可能超限
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        currentHandle = handle
    }

    private func cleanupOldFiles() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return }
        let infos: [LogFileInfo] = urls.compactMap { url in
            guard let day = LogFileNaming.day(of: url.lastPathComponent),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            else { return nil }
            return LogFileInfo(url: url, day: day, size: UInt64(size))
        }
        for url in LogRetentionPolicy.filesToDelete(infos, keepLatest: keepLatest, maxTotalBytes: maxTotalBytes) {
            // 当天正在写入的文件不删（策略已保证最新保留；此处兜底跳过）
            if url.lastPathComponent == LogFileNaming.fileName(for: clock.now) { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 熔断降级：记录一次后本会话不再写文件（os_log/内存缓冲不受影响）
    private func markFailure(_ message: String) {
        failureCount += 1
        disabled = true
        try? currentHandle?.close()
        currentHandle = nil
        Self.selfLogger.error("\(message, privacy: .public)（已停止文件日志，os_log 仍工作）")
    }
}
