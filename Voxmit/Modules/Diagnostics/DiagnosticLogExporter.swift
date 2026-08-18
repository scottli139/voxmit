import AppKit
import Foundation
import OSLog
import Speech

/// 诊断导出格式化（纯逻辑可单测）
enum DiagnosticLogFormatter {
    /// 每行："2026-08-18 12:30:01.123 INFO [download] 消息"
    static func formatEntry(date: Date, level: AppLogLevel, category: String, message: String) -> String {
        "\(timestamp(date)) \(level.label) [\(category)] \(message)"
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    /// 导出文件环境头。
    /// 隐私红线：不含 API Key 等凭据；转写/润色/剪贴板内容本体不落日志（规范见 implementation-notes）
    static func environmentHeader(
        appVersion: String,
        build: String,
        macOSVersion: String,
        machineArch: String,
        settings: [(key: String, value: String)],
        permissions: [(name: String, status: String)],
        scopeNote: String,
        logsDirectory: String,
        exportDate: Date
    ) -> String {
        var lines = [
            "# Voxmit 诊断日志导出",
            "# 导出时间：\(timestamp(exportDate))",
            "# App 版本：\(appVersion)（build \(build)）",
            "# macOS：\(macOSVersion)",
            "# 机型：\(machineArch)",
            "# \(scopeNote)",
            "# 完整日志目录：\(logsDirectory)（按日滚动，最近 7 个文件/20MB 内）",
        ]
        let settingsText = settings.map { "\($0.key)=\($0.value)" }.joined(separator: "，")
        lines.append("# 设置快照：\(settingsText)")
        let permissionText = permissions.map { "\($0.name)：\($0.status)" }.joined(separator: "，")
        lines.append("# 权限快照：\(permissionText)")
        lines.append("#（不含 API Key 等凭据；转写/润色文本本体不落日志）")
        return lines.joined(separator: "\n")
    }

    /// 组装导出全文（纯逻辑可单测）
    static func buildExportText(
        header: String,
        systemEntries: [LogRingBuffer.Entry]?,
        sessionEntries: [LogRingBuffer.Entry]
    ) -> String {
        var parts = [header]
        if let systemEntries {
            parts.append("\n== 系统日志（统一日志库，含历史进程）==")
            parts.append(
                systemEntries.isEmpty
                    ? "（该时段无条目）"
                    : systemEntries
                        .map { formatEntry(date: $0.date, level: $0.level, category: $0.category, message: $0.message) }
                        .joined(separator: "\n")
            )
        } else {
            parts.append("\n== 系统日志 ==\n（本机系统日志库不可用，略；实时日志可用 log stream 获取）")
        }
        parts.append("\n== 本次会话（内存缓冲）==")
        parts.append(
            sessionEntries.isEmpty
                ? "（无条目）"
                : sessionEntries
                    .map { formatEntry(date: $0.date, level: $0.level, category: $0.category, message: $0.message) }
                    .joined(separator: "\n")
        )
        return parts.joined(separator: "\n") + "\n"
    }
}

/// 系统日志采集通道（单测 mock；真实实现见 SystemLogCollector）
protocol DiagnosticLogCollecting: Sendable {
    /// 本 subsystem 最近 N 小时的条目；系统日志库不可用返回 nil
    func collectSystemEntries(hours: Int) async -> [LogRingBuffer.Entry]?
}

/// 真实采集：OSLogStore（.system scope，含历史进程）。
/// 实测结论（本机，macOS 26.6）：三种 scope 均抛错（logd 持久存储不可用，属环境特例）；
/// 用户正常机器上可用——不可用时返回 nil，由内存缓冲兜底（见 implementation-notes）。
struct SystemLogCollector: DiagnosticLogCollecting {
    let subsystem: String

    func collectSystemEntries(hours: Int) async -> [LogRingBuffer.Entry]? {
        guard let store = try? OSLogStore(scope: .system) else { return nil }
        let position = store.position(
            timeIntervalSinceLatestBoot: max(0, ProcessInfo.processInfo.systemUptime - TimeInterval(hours) * 3600)
        )
        guard let entries = try? store.getEntries(
            at: position,
            matching: NSPredicate(format: "subsystem == %@", subsystem)
        ) else { return nil }
        return entries.compactMap { $0 as? OSLogEntryLog }.map { entry in
            LogRingBuffer.Entry(
                date: entry.date,
                level: AppLogLevel(osLogLevel: entry.level),
                category: entry.category,
                message: entry.composedMessage
            )
        }
    }
}

extension AppLogLevel {
    init(osLogLevel: OSLogEntryLog.Level) {
        switch osLogLevel {
        case .debug: self = .debug
        case .info: self = .info
        case .notice: self = .notice
        case .error: self = .error
        case .fault: self = .fault
        default: self = .info // undefined 等
        }
    }
}

/// 诊断日志导出器：采集 + 环境头 + 保存面板 + 写文件
@MainActor
final class DiagnosticLogExporter {
    enum ExportOutcome: Equatable {
        case saved(URL)
        case cancelled
        case failed(String)
    }

    /// 导出文件名时间戳格式
    static let fileDateFormat = "yyyyMMdd-HHmm"

    private let collector: any DiagnosticLogCollecting
    private let permissionManager: PermissionManager

    init(
        collector: any DiagnosticLogCollecting = SystemLogCollector(
            subsystem: Bundle.main.bundleIdentifier ?? "com.voxmit.app"
        ),
        permissionManager: PermissionManager
    ) {
        self.collector = collector
        self.permissionManager = permissionManager
    }

    func export() async -> ExportOutcome {
        // 采集（collector 为异步非隔离实现，重活在池线程）
        async let systemEntriesTask = collector.collectSystemEntries(hours: 24)
        let sessionEntries = AppLog.recentEntries
        let systemEntries = await systemEntriesTask

        // 无日志条目（两端皆空）：给提示，不弹保存面板
        if (systemEntries?.isEmpty ?? true) && sessionEntries.isEmpty {
            return .failed("暂无可导出的日志条目（启动后尚未产生事件）")
        }

        let scopeNote = systemEntries != nil
            ? "系统日志口径：最近 24 小时（含历史进程）"
            : "系统日志库不可用，仅含本次会话内存缓冲"
        let header = DiagnosticLogFormatter.environmentHeader(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知",
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            machineArch: Self.machineArch(),
            settings: Self.settingsSnapshot(),
            permissions: permissionSnapshot(),
            scopeNote: scopeNote,
            logsDirectory: LogFileStore.defaultDirectory.path,
            exportDate: Date()
        )
        let text = DiagnosticLogFormatter.buildExportText(
            header: header,
            systemEntries: systemEntries,
            sessionEntries: sessionEntries
        )

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.log, .plainText]
        panel.nameFieldStringValue = "Voxmit-诊断日志-\(Self.fileTimestamp()).log"
        guard panel.runModal() == .OK, let url = panel.url else {
            return .cancelled
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            AppLog.info(.app, "诊断日志已导出：\(url.path)")
            return .saved(url)
        } catch {
            AppLog.error(.app, "诊断日志导出失败：\(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - 环境头数据

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = fileDateFormat
        return formatter.string(from: Date())
    }

    /// Apple Silicon / Intel
    static func machineArch() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buffer, &size, nil, 0)
        let machine = String(cString: buffer)
        return machine.hasPrefix("arm64") ? "Apple Silicon（\(machine)）" : "Intel（\(machine)）"
    }

    /// 关键设置快照（不含 API Key）
    static func settingsSnapshot() -> [(key: String, value: String)] {
        let defaults = UserDefaults.standard
        let hotkey = defaults.object(forKey: SettingsKeys.hotkeyKeyCode) != nil
            ? HotkeyPreset(keyCode: Int64(defaults.integer(forKey: SettingsKeys.hotkeyKeyCode))).displayName
            : HotkeyPreset.rightOption.displayName
        return [
            ("asr.engine", defaults.string(forKey: SettingsKeys.asrEngine) ?? "whisperkit"),
            ("asr.modelVariant", defaults.string(forKey: SettingsKeys.asrModelVariant) ?? "small"),
            ("asr.modelRepoEndpoint", defaults.string(forKey: SettingsKeys.asrModelRepoEndpoint) ?? "auto"),
            ("llm.refineEnabled", defaults.bool(forKey: SettingsKeys.llmRefineEnabled) ? "true" : "false"),
            ("inject.autoSend", defaults.bool(forKey: SettingsKeys.injectAutoSend) ? "true" : "false"),
            ("hotkeyPreset", hotkey),
        ]
    }

    private func permissionSnapshot() -> [(name: String, status: String)] {
        let snapshot = permissionManager.snapshot
        return [
            ("麦克风", Self.microphoneStatusText(snapshot.microphone)),
            ("输入监控", snapshot.listenEventGranted ? "已授权" : "未授权"),
            ("辅助功能", snapshot.accessibilityGranted ? "已授权" : "未授权"),
            ("语音识别", Self.speechStatusText(SFSpeechRecognizer.authorizationStatus())),
        ]
    }

    static func microphoneStatusText(_ status: MicrophonePermissionStatus) -> String {
        switch status {
        case .authorized: return "已授权"
        case .notDetermined: return "未请求"
        case .denied: return "已拒绝"
        case .restricted: return "受限"
        }
    }

    static func speechStatusText(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "已授权"
        case .notDetermined: return "未请求"
        case .denied: return "已拒绝"
        case .restricted: return "受限"
        @unknown default: return "未知"
        }
    }
}
