import Foundation
import Testing
@testable import Voxmit

/// 日志文件保留策略（纯逻辑）
struct LogRetentionPolicyTests {

    private func info(_ name: String, _ day: String, _ size: UInt64) -> LogFileInfo {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return LogFileInfo(
            url: URL(fileURLWithPath: "/logs/\(name)"),
            day: formatter.date(from: day)!,
            size: size
        )
    }

    @Test func filesToDelete_overCountLimit_dropsOldest() {
        let files = (1...9).map { info("voxmit-2026-08-0\($0).log", "2026-08-0\($0)", 1000) }

        let toDelete = LogRetentionPolicy.filesToDelete(files)

        // 保留最新 7 个（08-03…08-09），删最旧 2 个
        #expect(toDelete.count == 2)
        #expect(toDelete.contains(URL(fileURLWithPath: "/logs/voxmit-2026-08-01.log")))
        #expect(toDelete.contains(URL(fileURLWithPath: "/logs/voxmit-2026-08-02.log")))
    }

    @Test func filesToDelete_overSizeCap_dropsOldestBeyondCap() {
        // 3 个文件各 8MB（上限 20MB）：最新两个共 16MB 保留，最旧的删
        let files = [
            info("voxmit-2026-08-01.log", "2026-08-01", 8_000_000),
            info("voxmit-2026-08-02.log", "2026-08-02", 8_000_000),
            info("voxmit-2026-08-03.log", "2026-08-03", 8_000_000),
        ]
        #expect(LogRetentionPolicy.filesToDelete(files) == [URL(fileURLWithPath: "/logs/voxmit-2026-08-01.log")])
    }

    @Test func filesToDelete_newestOversized_olderDroppedBeyondCap() {
        // 最新（当天）文件单独超上限也保留（不删正在写入的文件）；
        // 但更旧的文件因总量超上限被删（上限语义优先）
        let files = [
            info("voxmit-2026-08-01.log", "2026-08-01", 1_000),
            info("voxmit-2026-08-18.log", "2026-08-18", 25_000_000),
        ]
        #expect(LogRetentionPolicy.filesToDelete(files) == [URL(fileURLWithPath: "/logs/voxmit-2026-08-01.log")])
    }

    @Test func filesToDelete_withinLimits_keepsAll() {
        let files = (1...3).map { info("voxmit-2026-08-0\($0).log", "2026-08-0\($0)", 100) }
        #expect(LogRetentionPolicy.filesToDelete(files).isEmpty)
    }
}

/// 按日命名与解析（纯逻辑）
struct LogFileNamingTests {

    @Test func fileName_dailyPatternAndRoundTrip() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.date(from: "2026-08-18")!

        #expect(LogFileNaming.fileName(for: date) == "voxmit-2026-08-18.log")
        #expect(LogFileNaming.day(of: "voxmit-2026-08-18.log") == date)
    }

    @Test func day_foreignFile_ignored() {
        // 不符合命名约定的文件不参与保留清理（防误删）
        #expect(LogFileNaming.day(of: "其他文件.txt") == nil)
        #expect(LogFileNaming.day(of: "voxmit-不是日期.log") == nil)
    }
}

/// 日志文件存储（临时目录 + 时钟注入）
struct LogFileStoreTests {

    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "voxmit-logtest-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func store_startupSeparatorAndAppend() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let store = LogFileStore(directory: dir, clock: MockClock())
        store.append(line: "2026-08-18 10:00:00.000 INFO [app] 测试行")
        store.flush()

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.count == 1)
        #expect(files[0] == "voxmit-1970-01-01.log") // MockClock 起点为 1970 纪元

        let content = try String(contentsOf: dir.appending(path: files[0]), encoding: .utf8)
        #expect(content.contains("App 启动，版本")) // 启动分隔行
        #expect(content.contains("测试行"))          // 追加内容
        #expect(store.failureCountForTesting == 0)
    }

    @Test func store_dayRollover_createsNewFile() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        let clock = MockClock()
        let store = LogFileStore(directory: dir, clock: clock)
        store.append(line: "第一天的行")
        store.flush() // 先排空队列再推进时钟（append 是异步入队，否则竞态）
        clock.advance(by: 86_400) // 跨天
        store.append(line: "第二天的行")
        store.flush()

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        try #require(files.count == 2)
        #expect(files == ["voxmit-1970-01-01.log", "voxmit-1970-01-02.log"])
        let day2 = try String(contentsOf: dir.appending(path: files[1]), encoding: .utf8)
        #expect(day2.contains("第二天的行"))
        #expect(!day2.contains("第一天的行"))
    }

    @Test func store_retentionAtStartup_keepsNewestSeven() throws {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        // 先建目录再落文件（createFile 不会自建父目录）
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 预置 9 个旧日志文件（2026-08-01…09，均早于真实"今天"）
        for day in 1...9 {
            let name = String(format: "voxmit-2026-08-%02d.log", day)
            FileManager.default.createFile(atPath: dir.appending(path: name).path, contents: Data("旧日志\n".utf8))
        }

        // SystemPipelineClock：今天最新，保留"今天 + 最近 6 天"共 7 个
        let store = LogFileStore(directory: dir, clock: SystemPipelineClock())
        store.flush()

        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(remaining.count == 7)
        #expect(!remaining.contains("voxmit-2026-08-01.log"))
        #expect(!remaining.contains("voxmit-2026-08-02.log"))
        #expect(!remaining.contains("voxmit-2026-08-03.log"))
        #expect(remaining.contains(LogFileNaming.fileName(for: Date())))
        #expect(store.failureCountForTesting == 0)
    }

    @Test func store_writeFailure_degradesSilently() {
        // 不可创建目录的路径：目录创建失败 → 熔断降级，不崩溃、不抛错
        let badDirectory = URL(fileURLWithPath: "/dev/null/impossible-\(UUID().uuidString)")
        let store = LogFileStore(directory: badDirectory, clock: MockClock())
        store.append(line: "会被丢弃")
        store.flush()

        #expect(store.failureCountForTesting > 0)

        // 熔断后继续写入是 no-op（不累积失败、不影响调用方）
        store.append(line: "再来一行")
        store.flush()
        #expect(store.failureCountForTesting == 1)
    }
}
