import Foundation
import Testing
@testable import Voxmit

/// 诊断导出格式化（纯逻辑）
struct DiagnosticLogFormatterTests {

    private let date = Date(timeIntervalSince1970: 1_787_040_000) // 固定时刻

    @Test func formatEntry_lineShape() {
        let line = DiagnosticLogFormatter.formatEntry(
            date: date, level: .error, category: "download", message: "模型下载失败：超时"
        )
        // 格式：时间 级别 [category] 消息
        #expect(line.hasSuffix("ERROR [download] 模型下载失败：超时"))
        #expect(line.contains("[download]"))
        let first = line.components(separatedBy: " ").first ?? ""
        #expect(first.matches(of: /^\d{4}-\d{2}-\d{2}$/).count == 1)
    }

    @Test func levelLabels_allLevels() {
        #expect(AppLogLevel.allCases.map(\.label) == ["DEBUG", "INFO", "NOTICE", "ERROR", "FAULT"])
    }

    @Test func environmentHeader_containsContextAndNoSecrets() {
        let header = DiagnosticLogFormatter.environmentHeader(
            appVersion: "1.0", build: "42",
            macOSVersion: "Version 26.6 (Build 25G5028f)",
            machineArch: "Apple Silicon（arm64）",
            settings: [("asr.engine", "whisperkit"), ("asr.modelVariant", "small")],
            permissions: [("麦克风", "已授权"), ("输入监控", "未授权")],
            scopeNote: "系统日志口径：最近 24 小时（含历史进程）",
            logsDirectory: "/Users/x/Library/Application Support/Voxmit/Logs",
            exportDate: date
        )
        #expect(header.contains("1.0（build 42）"))
        #expect(header.contains("Apple Silicon（arm64）"))
        #expect(header.contains("asr.engine=whisperkit"))
        #expect(header.contains("麦克风：已授权"))
        #expect(header.contains("最近 24 小时"))
        #expect(header.contains("Voxmit/Logs"))
        // 隐私红线：环境头不出现 Key/凭据字段
        #expect(!header.contains("API Key=") && !header.contains("apiKey"))
    }

    @Test func buildExportText_sectionsAndFallbackNote() {
        let header = "# 头"
        let system = [LogRingBuffer.Entry(date: date, level: .info, category: "app", message: "系统条目")]
        let session = [LogRingBuffer.Entry(date: date, level: .error, category: "audio", message: "会话条目")]

        let withSystem = DiagnosticLogFormatter.buildExportText(
            header: header, systemEntries: system, sessionEntries: session
        )
        #expect(withSystem.contains("== 系统日志（统一日志库，含历史进程）=="))
        #expect(withSystem.contains("INFO [app] 系统条目"))
        #expect(withSystem.contains("== 本次会话（内存缓冲）=="))
        #expect(withSystem.contains("ERROR [audio] 会话条目"))

        let noSystem = DiagnosticLogFormatter.buildExportText(
            header: header, systemEntries: nil, sessionEntries: session
        )
        #expect(noSystem.contains("系统日志库不可用"))
        #expect(!noSystem.contains("系统条目"))
    }

    @Test func buildExportText_emptySections_marked() {
        let text = DiagnosticLogFormatter.buildExportText(header: "# 头", systemEntries: [], sessionEntries: [])
        #expect(text.contains("（该时段无条目）"))
        #expect(text.contains("（无条目）"))
    }
}

/// 内存环形日志缓冲（诊断导出保底）
struct LogRingBufferTests {

    @Test func append_snapshotInOrder() {
        let buffer = LogRingBuffer(capacity: 10)
        buffer.append(date: Date(), level: .info, category: "app", message: "第一条")
        buffer.append(date: Date(), level: .error, category: "audio", message: "第二条")

        let snapshot = buffer.snapshot
        #expect(snapshot.count == 2)
        #expect(snapshot[0].message == "第一条")
        #expect(snapshot[1].level == .error)
    }

    @Test func append_overCapacity_evictsOldest() {
        let buffer = LogRingBuffer(capacity: 3)
        for i in 0..<5 {
            buffer.append(date: Date(), level: .debug, category: "hud", message: "第\(i)条")
        }
        let snapshot = buffer.snapshot
        #expect(snapshot.count == 3)
        #expect(snapshot.first?.message == "第2条") // 最旧两条被淘汰
        #expect(snapshot.last?.message == "第4条")
    }

    @Test func appLog_facade_writesRingBuffer() {
        // 环形缓冲是全进程单例，并行测试也会写入——用唯一标记定位本用例条目，不断言全局计数
        let marker = "单测打点-marker-\(UUID().uuidString)"
        AppLog.error(.pipeline, marker)

        let entry = AppLog.recentEntries.last { $0.message == marker }
        #expect(entry != nil)
        #expect(entry?.level == .error)
        #expect(entry?.category == "pipeline")
    }
}

/// 导出器环境头数据组装（真机系统状态只读，不触发弹窗）
@MainActor
struct DiagnosticLogExporterTests {

    @Test func machineArch_returnsChipFamily() {
        let arch = DiagnosticLogExporter.machineArch()
        #expect(arch.contains("Apple Silicon") || arch.contains("Intel"))
    }

    @Test func settingsSnapshot_noAPIKeyField() {
        let snapshot = DiagnosticLogExporter.settingsSnapshot()
        let keys = snapshot.map(\.key)
        #expect(keys.contains("asr.engine"))
        #expect(keys.contains("asr.modelRepoEndpoint"))
        #expect(keys.contains("hotkeyPreset"))
        // 隐私红线：不含 API Key（llm API Key 只存 Keychain，永不入日志/快照）
        #expect(!keys.contains { $0.lowercased().contains("apikey") || $0.lowercased().contains("api_key") })
    }

    @Test func microphoneAndSpeechStatusText_mapping() {
        #expect(DiagnosticLogExporter.microphoneStatusText(.authorized) == "已授权")
        #expect(DiagnosticLogExporter.microphoneStatusText(.notDetermined) == "未请求")
        #expect(DiagnosticLogExporter.speechStatusText(.denied) == "已拒绝")
    }
}
