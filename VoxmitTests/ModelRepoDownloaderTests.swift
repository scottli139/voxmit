import Foundation
import Testing
@testable import Voxmit

/// 清单解析与命名（纯逻辑）
struct ModelRepoManifestTests {

    /// tree API 结构样例（含目录项、正常文件、缺 size 的镜像小文件）
    private let fixture = Data("""
    [
      {"type":"directory","path":"openai_whisper-small"},
      {"type":"file","path":"openai_whisper-small/config.json","size":2400},
      {"type":"file","path":"openai_whisper-small/AudioEncoder.mlmodelc/weights/weights.bin","size":1000000},
      {"type":"file","path":"openai_whisper-small/generation_config.json"}
    ]
    """.utf8)

    @Test func parseFileEntries_filtersFilesWithSizes() throws {
        let entries = try ModelRepoManifest.parseFileEntries(fixture)

        #expect(entries.count == 3) // 目录项跳过
        #expect(entries[0].path == "openai_whisper-small/config.json")
        #expect(entries[0].size == 2400)
        #expect(entries[1].size == 1000000)
        #expect(entries[2].size == nil) // 镜像小文件无 size
    }

    @Test func parseFileEntries_invalidJSON_throws() {
        #expect(throws: RepoDownloadError.self) {
            _ = try ModelRepoManifest.parseFileEntries(Data("not json".utf8))
        }
    }

    @Test func naming_variantAndTokenizerMapping() {
        #expect(ModelRepoManifest.variantDirectoryName("small") == "openai_whisper-small")
        #expect(ModelRepoManifest.variantDirectoryName("large-v3") == "openai_whisper-large-v3")
        #expect(ModelRepoManifest.tokenizerRepoID("small") == "openai/whisper-small")
        #expect(ModelRepoManifest.tokenizerFiles == ["tokenizer.json", "tokenizer_config.json"])
    }

    @Test func urls_manifestAndFile() {
        let manifest = ModelRepoManifest.manifestURL(endpoint: "https://hf-mirror.com", variant: "small")
        #expect(manifest?.absoluteString == "https://hf-mirror.com/api/models/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-small?recursive=true")
        let file = ModelRepoManifest.fileURL(
            endpoint: "https://hf-mirror.com", repoID: "argmaxinc/whisperkit-coreml",
            path: "openai_whisper-small/config.json"
        )
        #expect(file?.absoluteString == "https://hf-mirror.com/argmaxinc/whisperkit-coreml/resolve/main/openai_whisper-small/config.json")
    }
}

/// 进度聚合（纯逻辑）
struct DownloadProgressTrackerTests {

    @Test func fraction_registerAdvanceAndBackfill() {
        let tracker = DownloadProgressTracker()
        tracker.register(path: "a", expected: 1000, alreadyHave: 0)
        tracker.register(path: "b", expected: nil, alreadyHave: 200) // 大小未知：不计入总量
        #expect(tracker.totalExpectedBytes == 1000)
        #expect(tracker.downloadedBytes == 200)

        tracker.advance(path: "a", to: 500)
        #expect(abs(tracker.fraction - 0.7) < 0.001) // (500+200)/1000

        tracker.setExpected(path: "b", 400) // 响应到达回填
        #expect(tracker.totalExpectedBytes == 1400)
        #expect(abs(tracker.fraction - 0.5) < 0.001) // (500+200)/1400

        tracker.advance(path: "a", to: 1000)
        tracker.advance(path: "b", to: 400)
        #expect(tracker.fraction == 1.0)
    }

    @Test func fraction_noKnownSizes_zero() {
        let tracker = DownloadProgressTracker()
        tracker.register(path: "a", expected: nil, alreadyHave: 0)
        #expect(tracker.fraction == 0)
    }
}

/// 下载编排器（mock HTTP 通道 + 临时目录 + MockClock，零真实网络）
struct ModelRepoDownloaderTests {

    private let manifestFixture = Data("""
    [
      {"type":"directory","path":"openai_whisper-small"},
      {"type":"file","path":"openai_whisper-small/config.json","size":1000},
      {"type":"file","path":"openai_whisper-small/AudioEncoder.mlmodelc/weights.bin","size":2000}
    ]
    """.utf8)

    /// mock HTTP 通道：清单固定；文件按预期大小写零字节到目标路径（含 destination 已存在语义由编排器保证）
    private final class MockRepoHTTPClient: RepoHTTPClient, @unchecked Sendable {
        var manifestData: Data = Data()
        var manifestError: (any Error)?
        /// path（源 URL path）→ 前 N 次失败
        var failuresPerPath: [String: Int] = [:]
        /// path → 文件大小覆盖（默认 1000）
        var sizeOverrides: [String: Int64] = [:]

        private(set) var jsonURLs: [URL] = []
        private(set) var downloads: [(url: URL, destination: URL, resumeFrom: Int64)] = []
        private var attempts: [String: Int] = [:]

        func getJSON(_ url: URL) async throws -> Data {
            jsonURLs.append(url)
            if let manifestError { throw manifestError }
            return manifestData
        }

        func downloadFile(
            _ url: URL,
            to destination: URL,
            resumeFrom: Int64,
            progress: @Sendable @escaping (Int64) -> Void
        ) async throws -> Int64? {
            downloads.append((url, destination, resumeFrom))
            let key = url.path
            attempts[key, default: 0] += 1
            if attempts[key]! <= failuresPerPath[key] ?? 0 {
                throw RepoDownloadError.httpStatus(500, key)
            }
            let expected = sizeOverrides[key] ?? 1000
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 0, count: Int(expected)).write(to: destination)
            progress(expected)
            return expected
        }
    }

    private func makeTempBase() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "voxmit-repodl-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeDownloader(
        client: MockRepoHTTPClient, clock: MockClock
    ) -> ModelRepoDownloader {
        client.manifestData = manifestFixture
        return ModelRepoDownloader(client: client, clock: clock)
    }

    private var modelFolderPath: String {
        "models/argmaxinc/whisperkit-coreml/openai_whisper-small"
    }

    /// 进度记录器（@Sendable 闭包内可变访问）
    private final class FractionRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []
        func append(_ value: Double) { lock.withLock { values.append(value) } }
        var all: [Double] { lock.withLock { values } }
    }

    @Test func download_happyPath_allFilesLandAndTokenizerAtRoot() async throws {
        let client = MockRepoHTTPClient()
        let clock = MockClock()
        let downloader = makeDownloader(client: client, clock: clock)
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let recorder = FractionRecorder()

        let folder = try await downloader.download(
            variant: "small", endpoint: "https://hf-mirror.com", downloadBase: base
        ) { recorder.append($0) }
        let fractions = recorder.all

        // 模型目录 + 两个模型文件 + tokenizer 两文件在目录根
        #expect(folder.lastPathComponent == "openai_whisper-small")
        #expect(FileManager.default.fileExists(
            atPath: base.appending(path: "\(modelFolderPath)/config.json").path))
        #expect(FileManager.default.fileExists(
            atPath: base.appending(path: "\(modelFolderPath)/AudioEncoder.mlmodelc/weights.bin").path))
        #expect(FileManager.default.fileExists(
            atPath: base.appending(path: "\(modelFolderPath)/tokenizer.json").path))
        #expect(FileManager.default.fileExists(
            atPath: base.appending(path: "\(modelFolderPath)/tokenizer_config.json").path))
        // 清单请求 + tokenizer 仓库 URL 正确
        #expect(client.jsonURLs.first?.absoluteString.contains("/api/models/argmaxinc/whisperkit-coreml/tree/main/openai_whisper-small") == true)
        #expect(client.downloads.contains { $0.url.absoluteString.contains("openai/whisper-small/resolve/main/tokenizer.json") })
        // 进度到达 100%
        #expect(fractions.last == 1.0)
    }

    @Test func download_partialExists_resumesWithRange() async throws {
        let client = MockRepoHTTPClient()
        let clock = MockClock()
        let downloader = makeDownloader(client: client, clock: clock)
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        // 预置半截 partial（300/1000）
        let configDest = base.appending(path: "\(modelFolderPath)/config.json")
        let partial = configDest.appendingPathExtension("partial")
        try FileManager.default.createDirectory(
            at: configDest.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0, count: 300).write(to: partial)

        _ = try await downloader.download(
            variant: "small", endpoint: "https://hf-mirror.com", downloadBase: base
        ) { _ in }

        let configDownload = client.downloads.first { $0.destination.lastPathComponent == "config.json" }
        #expect(configDownload?.resumeFrom == 300) // Range 续传起点
    }

    @Test func download_destinationComplete_skipsNetwork() async throws {
        let client = MockRepoHTTPClient()
        let clock = MockClock()
        let downloader = makeDownloader(client: client, clock: clock)
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        // config.json 已完整存在（原子移动落盘即完整）
        let configDest = base.appending(path: "\(modelFolderPath)/config.json")
        try FileManager.default.createDirectory(
            at: configDest.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0, count: 1000).write(to: configDest)

        _ = try await downloader.download(
            variant: "small", endpoint: "https://hf-mirror.com", downloadBase: base
        ) { _ in }

        // 已完成文件不再走网络；其余文件正常下载
        #expect(!client.downloads.contains { $0.destination.lastPathComponent == "config.json" })
        #expect(client.downloads.contains { $0.destination.lastPathComponent == "weights.bin" })
    }

    @Test func download_fileFailsOnce_retriesWithBackoff() async throws {
        let client = MockRepoHTTPClient()
        client.failuresPerPath = [
            "/argmaxinc/whisperkit-coreml/resolve/main/openai_whisper-small/config.json": 1,
        ]
        let clock = MockClock()
        let downloader = makeDownloader(client: client, clock: clock)
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let task = Task {
            try await downloader.download(
                variant: "small", endpoint: "https://hf-mirror.com", downloadBase: base
            ) { _ in }
        }
        // 让下载推进到退避挂起点，然后推进虚拟时钟放行重试
        for _ in 0..<12 { await Task { @MainActor in }.value }
        clock.advance(by: ModelRepoDownloader.retryBackoffs[0])
        for _ in 0..<12 { await Task { @MainActor in }.value }

        _ = try await task.value
        // 失败一次后重试成功：该文件两次尝试
        let key = "/argmaxinc/whisperkit-coreml/resolve/main/openai_whisper-small/config.json"
        #expect(client.downloads.filter { $0.url.path == key }.count == 2)
    }

    @Test func download_retriesExhausted_throws() async throws {
        let client = MockRepoHTTPClient()
        let key = "/argmaxinc/whisperkit-coreml/resolve/main/openai_whisper-small/config.json"
        client.failuresPerPath = [key: 3] // 1 + 2 次重试全败
        let clock = MockClock()
        let downloader = makeDownloader(client: client, clock: clock)
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let task = Task {
            try await downloader.download(
                variant: "small", endpoint: "https://hf-mirror.com", downloadBase: base
            ) { _ in }
        }
        for _ in 0..<12 { await Task { @MainActor in }.value }
        clock.advance(by: ModelRepoDownloader.retryBackoffs[0])
        for _ in 0..<12 { await Task { @MainActor in }.value }
        clock.advance(by: ModelRepoDownloader.retryBackoffs[1])
        for _ in 0..<12 { await Task { @MainActor in }.value }

        await #expect(throws: RepoDownloadError.self) { try await task.value }
        #expect(client.downloads.filter { $0.url.path == key }.count == 3)
    }

    @Test func download_manifestFails_noFileDownloads() async throws {
        let client = MockRepoHTTPClient()
        client.manifestError = RepoDownloadError.httpStatus(503, "tree")
        let clock = MockClock()
        let downloader = makeDownloader(client: client, clock: clock)
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        await #expect(throws: RepoDownloadError.self) {
            _ = try await downloader.download(
                variant: "small", endpoint: "https://hf-mirror.com", downloadBase: base
            ) { _ in }
        }
        #expect(client.downloads.isEmpty)
    }

    @Test func download_cancelledDuringBackoff_noFurtherDownloads() async throws {
        let client = MockRepoHTTPClient()
        let key = "/argmaxinc/whisperkit-coreml/resolve/main/openai_whisper-small/config.json"
        client.failuresPerPath = [key: 99] // 一直失败，逼出退避
        let clock = MockClock()
        let downloader = makeDownloader(client: client, clock: clock)
        let base = try makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }

        let task = Task {
            try await downloader.download(
                variant: "small", endpoint: "https://hf-mirror.com", downloadBase: base
            ) { _ in }
        }
        for _ in 0..<12 { await Task { @MainActor in }.value }
        task.cancel() // 退避中取消
        for _ in 0..<12 { await Task { @MainActor in }.value }

        await #expect(throws: CancellationError.self) { try await task.value }
        // 取消后不再下载其他文件
        #expect(!client.downloads.contains { $0.destination.lastPathComponent == "weights.bin" })
    }
}
