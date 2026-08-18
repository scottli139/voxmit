import Combine
import Foundation
import Testing
@testable import Voxmit

/// 引擎切换决策（TranscriptionEngineResolver 纯逻辑矩阵，§4.2.3）
struct TranscriptionEngineResolverTests {

    @Test func resolve_speechSetting_alwaysSpeech() {
        #expect(TranscriptionEngineResolver.resolve(setting: "speech", modelReady: true) == .speech)
        #expect(TranscriptionEngineResolver.resolve(setting: "speech", modelReady: false) == .speech)
    }

    @Test func resolve_whisperkit_modelReady_whisperKit() {
        #expect(TranscriptionEngineResolver.resolve(setting: "whisperkit", modelReady: true) == .whisperKit)
    }

    @Test func resolve_whisperkit_modelNotReady_speechFallback() {
        // 模型下载完成前自动以 Speech 框架兜底（§4.2.3）
        #expect(TranscriptionEngineResolver.resolve(setting: "whisperkit", modelReady: false) == .speech)
    }

    @Test func resolve_cloudOrUnknown_fallsBackToLocalDefault() {
        // 云端 ASR 为 P1 未实现：回落本地默认路径
        #expect(TranscriptionEngineResolver.resolve(setting: "cloud", modelReady: true) == .whisperKit)
        #expect(TranscriptionEngineResolver.resolve(setting: "cloud", modelReady: false) == .speech)
        #expect(TranscriptionEngineResolver.resolve(setting: "bogus", modelReady: false) == .speech)
    }
}

/// 模型下载状态机（mock 下载通道，无真实网络）
@MainActor
struct ModelDownloadManagerTests {

    /// 状态序列收集（@Published 在主 Actor 同步发出，assumeIsolated 安全）
    @MainActor
    private final class StateCollector {
        private(set) var states: [ModelDownloadState] = []
        private var cancellable: AnyCancellable?
        func attach(to manager: ModelDownloadManager) {
            cancellable = manager.$state.sink { [weak self] state in
                MainActor.assumeIsolated { self?.states.append(state) }
            }
        }
    }

    private func settle() async {
        for _ in 0..<12 {
            await Task { @MainActor in }.value
        }
    }

    @Test func init_modelExistsOnDisk_startsReady() {
        let downloader = MockModelDownloader()
        downloader.existingFolder = URL(fileURLWithPath: "/tmp")

        let manager = ModelDownloadManager(downloader: downloader)

        #expect(manager.state == .ready)
        #expect(manager.modelFolder != nil)
    }

    @Test func startDownload_progressesToReady() async {
        let downloader = MockModelDownloader()
        let manager = ModelDownloadManager(downloader: downloader)
        let collector = StateCollector()
        collector.attach(to: manager)
        #expect(manager.state == .notStarted)

        manager.startDownloadIfNeeded()
        await settle()

        #expect(downloader.downloadCallCount == 1)
        #expect(downloader.reportedProgress == [0.2, 0.6, 1.0])
        #expect(manager.state == .ready)
        // 状态序列：起点 → 下载中（含进度）→ 就绪
        #expect(collector.states.first == .notStarted)
        #expect(collector.states.contains(.downloading(0.6)))
        #expect(collector.states.last == .ready)
    }

    @Test func startDownload_failure_setsFailedThenRetrySucceeds() async {
        let downloader = MockModelDownloader()
        downloader.downloadError = NSError(
            domain: "mock", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "模拟网络失败"]
        )
        let manager = ModelDownloadManager(downloader: downloader)

        manager.startDownloadIfNeeded()
        await settle()

        guard case .failed(let message) = manager.state else {
            Issue.record("期望 failed 状态，实际 \(manager.state)")
            return
        }
        #expect(message == "模拟网络失败")

        // 重试成功
        downloader.downloadError = nil
        manager.startDownloadIfNeeded()
        await settle()

        #expect(downloader.downloadCallCount == 2)
        #expect(manager.state == .ready)
    }

    @Test func startDownload_whileDownloading_noDuplicateTask() async {
        let downloader = MockModelDownloader()
        downloader.delay = 60 // 挂起 60 虚拟秒，制造"下载中"窗口
        downloader.delayClock = MockClock()
        let manager = ModelDownloadManager(downloader: downloader)
        let clock = downloader.delayClock!

        manager.startDownloadIfNeeded()
        await settle()
        guard case .downloading = manager.state else {
            Issue.record("期望 downloading 状态，实际 \(manager.state)")
            return
        }

        manager.startDownloadIfNeeded() // 下载中重复调用：不重复下载
        #expect(downloader.downloadCallCount == 1)

        clock.advance(by: 60)
        await settle()
        #expect(manager.state == .ready)
        #expect(downloader.downloadCallCount == 1)
    }

    @Test func startDownload_returnedFolderMissing_setsFailed() async {
        let downloader = MockModelDownloader()
        downloader.returnedFolder = URL(fileURLWithPath: "/nonexistent-voxmit-mock-path")
        let manager = ModelDownloadManager(downloader: downloader)

        manager.startDownloadIfNeeded()
        await settle()

        // 落盘校验失败（需求文档 §4.2.3：校验失败提示重新下载）
        guard case .failed = manager.state else {
            Issue.record("期望 failed 状态，实际 \(manager.state)")
            return
        }
    }

    @Test func reevaluate_variantFolderGone_backToNotStarted() {
        let downloader = MockModelDownloader()
        downloader.existingFolder = URL(fileURLWithPath: "/tmp")
        let manager = ModelDownloadManager(downloader: downloader)
        #expect(manager.state == .ready)

        downloader.existingFolder = nil // 模拟切换模型规格后新变体未下载
        manager.reevaluate()

        #expect(manager.state == .notStarted)
        #expect(manager.modelFolder == nil)
    }
}

/// 端点尝试顺序决策（ModelRepoEndpointResolver 纯逻辑；HF 镜像回退）
struct ModelRepoEndpointResolverTests {

    @Test func attemptOrder_autoUnset_officialThenMirror() {
        #expect(ModelRepoEndpointResolver.attemptOrder(setting: nil) == [.huggingface, .hfMirror])
        #expect(ModelRepoEndpointResolver.attemptOrder(setting: "auto") == [.huggingface, .hfMirror])
    }

    @Test func attemptOrder_forced_onlyThatEndpoint() {
        #expect(ModelRepoEndpointResolver.attemptOrder(setting: "huggingface") == [.huggingface])
        #expect(ModelRepoEndpointResolver.attemptOrder(setting: "hf-mirror") == [.hfMirror])
    }

    @Test func attemptOrder_unknown_fallsBackToAutoChain() {
        #expect(ModelRepoEndpointResolver.attemptOrder(setting: "bogus") == [.huggingface, .hfMirror])
    }
}

/// 下载器端点回退（mock 执行点，零真实网络）
struct WhisperKitModelDownloaderTests {

    /// 单次尝试记录（端点 + 会话类型）
    private struct Attempt: Equatable {
        let endpoint: ModelRepoEndpoint
        let background: Bool
    }

    /// 执行点记录器（@Sendable 闭包内可变访问，测试内串行）
    private final class ExecutorRecorder: @unchecked Sendable {
        private(set) var attempts: [Attempt] = []
        /// 行为（默认成功返回 /tmp）；参数为（端点，是否后台 session）
        var behavior: (ModelRepoEndpoint, Bool) throws -> URL = { _, _ in URL(fileURLWithPath: "/tmp") }

        func makeExecutor() -> WhisperKitModelDownloader.DownloadExecutor {
            { _, endpoint, _, useBackgroundSession, progress in
                self.attempts.append(Attempt(endpoint: endpoint, background: useBackgroundSession))
                progress(1.0)
                return try self.behavior(endpoint, useBackgroundSession)
            }
        }
    }

    private func makeDownloader(
        chain: [ModelRepoEndpoint],
        recorder: ExecutorRecorder
    ) -> WhisperKitModelDownloader {
        WhisperKitModelDownloader(
            variantProvider: { "small" },
            downloadBase: URL(fileURLWithPath: "/tmp"),
            endpointChain: { chain },
            executeDownload: recorder.makeExecutor()
        )
    }

    @Test func download_primaryFails_mirrorSucceeds() async throws {
        let recorder = ExecutorRecorder()
        recorder.behavior = { endpoint, _ in
            if endpoint == .huggingface { throw NSError(domain: "mock", code: -1001) } // 超时
            return URL(fileURLWithPath: "/tmp")
        }
        let downloader = makeDownloader(chain: ModelRepoEndpointResolver.attemptOrder(setting: nil), recorder: recorder)

        let folder = try await downloader.download { _ in }

        // 官方失败后自动回退镜像（均后台 session）
        #expect(recorder.attempts == [
            Attempt(endpoint: .huggingface, background: true),
            Attempt(endpoint: .hfMirror, background: true),
        ])
        #expect(folder.lastPathComponent == "tmp")
    }

    @Test func download_bothFail_throwsCombinedError() async {
        let recorder = ExecutorRecorder()
        recorder.behavior = { _, _ in throw NSError(domain: "mock", code: -1001, userInfo: [NSLocalizedDescriptionKey: "连接超时"]) }
        let downloader = makeDownloader(chain: [.huggingface, .hfMirror], recorder: recorder)

        do {
            _ = try await downloader.download { _ in }
            Issue.record("两端点失败应抛错")
        } catch let error as ModelDownloadError {
            guard case .allEndpointsFailed(let failures) = error else {
                Issue.record("期望 allEndpointsFailed，实际 \(error)")
                return
            }
            #expect(failures.count == 2)
            // 错误信息注明两个端点都不可达
            #expect(error.localizedDescription.contains("huggingface.co"))
            #expect(error.localizedDescription.contains("hf-mirror.com"))
        } catch {
            Issue.record("错误类型不符：\(error)")
        }
        #expect(recorder.attempts.count == 2)
    }

    @Test func download_cancelled_noFallback() async {
        let recorder = ExecutorRecorder()
        recorder.behavior = { _, _ in throw CancellationError() }
        let downloader = makeDownloader(chain: [.huggingface, .hfMirror], recorder: recorder)

        do {
            _ = try await downloader.download { _ in }
            Issue.record("应抛出 CancellationError")
        } catch is CancellationError {
            // 预期
        } catch {
            Issue.record("错误类型不符：\(error)")
        }
        // 取消不回退：镜像端点未被尝试
        #expect(recorder.attempts == [Attempt(endpoint: .huggingface, background: true)])
    }

    @Test func download_forcedEndpoint_onlyTriesIt() async throws {
        let recorder = ExecutorRecorder()
        let downloader = makeDownloader(
            chain: ModelRepoEndpointResolver.attemptOrder(setting: "hf-mirror"),
            recorder: recorder
        )

        _ = try await downloader.download { _ in }

        #expect(recorder.attempts == [Attempt(endpoint: .hfMirror, background: true)])
    }

    // MARK: - 后台传输服务不可用（-997）回退前台 session

    @Test func download_backgroundLostConnection_foregroundRetrySameEndpoint() async throws {
        let recorder = ExecutorRecorder()
        let lostBackground = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorBackgroundSessionWasDisconnected // -997
        )
        recorder.behavior = { _, background in
            if background { throw lostBackground }
            return URL(fileURLWithPath: "/tmp")
        }
        let downloader = makeDownloader(chain: [.huggingface], recorder: recorder)

        let folder = try await downloader.download { _ in }

        // 同端点后台→前台回退，不进入下一端点
        #expect(recorder.attempts == [
            Attempt(endpoint: .huggingface, background: true),
            Attempt(endpoint: .huggingface, background: false),
        ])
        #expect(folder.lastPathComponent == "tmp")
    }

    @Test func download_backgroundSucceeds_noForegroundAttempt() async throws {
        let recorder = ExecutorRecorder()
        let downloader = makeDownloader(chain: [.huggingface, .hfMirror], recorder: recorder)

        _ = try await downloader.download { _ in }

        #expect(recorder.attempts == [Attempt(endpoint: .huggingface, background: true)])
    }

    @Test func download_nonTransportError_noForegroundRetry() async {
        let recorder = ExecutorRecorder()
        recorder.behavior = { _, _ in throw NSError(domain: "mock", code: -1001) } // 普通超时
        let downloader = makeDownloader(chain: [.huggingface], recorder: recorder)

        do {
            _ = try await downloader.download { _ in }
            Issue.record("应抛错")
        } catch {
            // 预期
        }
        // 非 -997 不触发前台回退
        #expect(recorder.attempts == [Attempt(endpoint: .huggingface, background: true)])
    }
}

/// -997 判定（按错误码，不匹配文案）
struct DownloadTransportErrorTests {

    @Test func isLostBackgroundTransferConnection_matrix() {
        #expect(WhisperKitModelDownloader.isLostBackgroundTransferConnection(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorBackgroundSessionWasDisconnected)
        ))
        // 真超时不算（huggingface 被墙的正确行为）
        #expect(!WhisperKitModelDownloader.isLostBackgroundTransferConnection(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        ))
        // 同码不同域不算
        #expect(!WhisperKitModelDownloader.isLostBackgroundTransferConnection(
            NSError(domain: "mock", code: -997)
        ))
    }
}

/// Speech 错误映射（听写关闭 → 可操作文案）
struct SpeechErrorMapperTests {

    @Test func map_dictationDisabledError_mapsToActionableMessage() {
        // "Siri and Dictation are disabled" 来自运行时 AssistantServices（SDK 无公开错误码）
        let error = NSError(
            domain: "kAFAssistantErrorDomain",
            code: 217,
            userInfo: [NSLocalizedDescriptionKey: "Siri and Dictation are disabled"]
        )
        let mapped = SpeechErrorMapper.map(error)
        #expect(mapped as? SpeechEngineError == .dictationDisabled)
        #expect(mapped.localizedDescription.contains("听写"))
    }

    @Test func map_unrelatedError_passesThrough() {
        let error = NSError(domain: "mock", code: 1, userInfo: [NSLocalizedDescriptionKey: "其他错误"])
        let mapped = SpeechErrorMapper.map(error) as NSError
        #expect(mapped.domain == "mock")
        #expect(mapped.code == 1)
    }
}

/// Speech 识别语言解析（asr.speechLocale，默认 zh-CN）
struct SpeechLocaleResolverTests {

    @Test func resolve_unset_defaultsToZhCN() {
        #expect(SpeechLocaleResolver.resolve(setting: nil) == "zh-CN")
    }

    @Test func resolve_explicitOverride_usedAsIs() {
        #expect(SpeechLocaleResolver.resolve(setting: "en-US") == "en-US")
    }

    @Test func resolve_blankOrWhitespace_fallsBackToZhCN() {
        #expect(SpeechLocaleResolver.resolve(setting: "") == "zh-CN")
        #expect(SpeechLocaleResolver.resolve(setting: "   ") == "zh-CN")
    }
}

/// Speech 引擎错误文案（可操作性断言；不裸抛英文系统错误）
struct SpeechEngineErrorTests {

    @Test func localeUnsupported_messageGuidesToZhCN() {
        let text = SpeechEngineError.localeUnsupported("xx-XX").localizedDescription
        #expect(text.contains("zh-CN"))
        #expect(text.contains("WhisperKit"))
    }

    @Test func onDeviceLanguageMissing_messageGuidesToDictationLanguages() {
        let text = SpeechEngineError.onDeviceLanguageMissing("zh-CN").localizedDescription
        #expect(text.contains("键盘"))
        #expect(text.contains("听写"))
        #expect(text.contains("语言"))
        #expect(text.contains("zh-CN"))
    }
}

/// 模型目录就绪校验（完整产物集：config.json + 三个 .mlmodelc 目录包，缺一即不完整）
struct ModelFolderValidatorTests {

    private func makeDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "voxmit-modeltest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// 造齐完整产物集
    private func populateCompleteSet(_ dir: URL) throws {
        FileManager.default.createFile(atPath: dir.appending(path: "config.json").path, contents: Data("{}".utf8))
        for package in ModelFolderValidator.requiredPackages {
            try FileManager.default.createDirectory(
                at: dir.appending(path: package), withIntermediateDirectories: true
            )
        }
    }

    @Test func isReady_completeArtifactSet_true() throws {
        let dir = try makeDir("ready")
        defer { cleanup(dir) }
        try populateCompleteSet(dir)
        #expect(ModelFolderValidator.isReady(dir))
    }

    @Test func isReady_emptyDirectory_false() throws {
        let dir = try makeDir("empty")
        defer { cleanup(dir) }
        #expect(!ModelFolderValidator.isReady(dir))
    }

    @Test func isReady_missingOnePackage_false() throws {
        let dir = try makeDir("missing-encoder")
        defer { cleanup(dir) }
        // 缺 AudioEncoder.mlmodelc（真机残骸实况：只有部分产物包）
        FileManager.default.createFile(atPath: dir.appending(path: "config.json").path, contents: Data("{}".utf8))
        for package in ["MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"] {
            try FileManager.default.createDirectory(
                at: dir.appending(path: package), withIntermediateDirectories: true
            )
        }
        #expect(!ModelFolderValidator.isReady(dir))
    }

    @Test func isReady_missingConfigJson_false() throws {
        let dir = try makeDir("no-config")
        defer { cleanup(dir) }
        for package in ModelFolderValidator.requiredPackages {
            try FileManager.default.createDirectory(
                at: dir.appending(path: package), withIntermediateDirectories: true
            )
        }
        #expect(!ModelFolderValidator.isReady(dir))
    }

    @Test func isReady_mlmodelcAsPlainFile_false() throws {
        let dir = try makeDir("file-not-dir")
        defer { cleanup(dir) }
        FileManager.default.createFile(atPath: dir.appending(path: "config.json").path, contents: Data("{}".utf8))
        // .mlmodelc 是普通文件而非目录包：不算（产物一定是目录）
        FileManager.default.createFile(atPath: dir.appending(path: "AudioEncoder.mlmodelc").path, contents: Data())
        for package in ["MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"] {
            try FileManager.default.createDirectory(
                at: dir.appending(path: package), withIntermediateDirectories: true
            )
        }
        #expect(!ModelFolderValidator.isReady(dir))
    }

    @Test func isReady_nonexistentPath_false() {
        #expect(!ModelFolderValidator.isReady(URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")))
    }
}

/// 就绪校验加强后的目录判定（existingModelFolder 走残骸 → nil）
struct ModelFolderReadinessTests {

    private func makeRepoDir() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "voxmit-repotest-\(UUID().uuidString)", directoryHint: .isDirectory)
        let repo = base.appending(path: "models/argmaxinc/whisperkit-coreml", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        return base
    }

    @Test func existingModelFolder_variantWithArtifact_returnsFolder() throws {
        let base = try makeRepoDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let variantDir = base
            .appending(path: "models/argmaxinc/whisperkit-coreml/openai_whisper-small")
        try FileManager.default.createDirectory(at: variantDir, withIntermediateDirectories: true)
        // 完整产物集：config.json + 三个 .mlmodelc 目录包
        FileManager.default.createFile(atPath: variantDir.appending(path: "config.json").path, contents: Data("{}".utf8))
        for package in ModelFolderValidator.requiredPackages {
            try FileManager.default.createDirectory(
                at: variantDir.appending(path: package), withIntermediateDirectories: true
            )
        }
        let downloader = WhisperKitModelDownloader(
            variantProvider: { "small" }, downloadBase: base, endpointChain: { [.huggingface] }
        )
        #expect(downloader.existingModelFolder()?.lastPathComponent == "openai_whisper-small")
    }

    @Test func existingModelFolder_variantPartialArtifacts_returnsNil() throws {
        let base = try makeRepoDir()
        defer { try? FileManager.default.removeItem(at: base) }
        // 部分残骸：config.json + 仅 MelSpectrogram（缺 AudioEncoder/TextDecoder）——真机实况
        let variantDir = base
            .appending(path: "models/argmaxinc/whisperkit-coreml/openai_whisper-small")
        try FileManager.default.createDirectory(at: variantDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: variantDir.appending(path: "config.json").path, contents: Data("{}".utf8))
        try FileManager.default.createDirectory(
            at: variantDir.appending(path: "MelSpectrogram.mlmodelc"), withIntermediateDirectories: true
        )
        let downloader = WhisperKitModelDownloader(
            variantProvider: { "small" }, downloadBase: base, endpointChain: { [.huggingface] }
        )
        #expect(downloader.existingModelFolder() == nil)
    }

    @Test func removeInvalidModel_deletesVariantDirectoryEvenIfWreckage() throws {
        let base = try makeRepoDir()
        defer { try? FileManager.default.removeItem(at: base) }
        // 残骸目录（不就绪）：自愈删除也必须命中（不做就绪校验）
        let variantDir = base
            .appending(path: "models/argmaxinc/whisperkit-coreml/openai_whisper-small")
        try FileManager.default.createDirectory(
            at: variantDir.appending(path: "MelSpectrogram.mlmodelc"), withIntermediateDirectories: true
        )
        let downloader = WhisperKitModelDownloader(
            variantProvider: { "small" }, downloadBase: base, endpointChain: { [.huggingface] }
        )

        downloader.removeInvalidModel()

        #expect(!FileManager.default.fileExists(atPath: variantDir.path))
    }

    @Test func existingModelFolder_variantWreckage_returnsNil() throws {
        let base = try makeRepoDir()
        defer { try? FileManager.default.removeItem(at: base) }
        // 残骸：目录在、只有 config.json，无 .mlmodelc（首次超时遗留场景）
        let variantDir = base
            .appending(path: "models/argmaxinc/whisperkit-coreml/openai_whisper-small")
        try FileManager.default.createDirectory(at: variantDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: variantDir.appending(path: "config.json").path, contents: Data("{}".utf8))
        let downloader = WhisperKitModelDownloader(
            variantProvider: { "small" }, downloadBase: base, endpointChain: { [.huggingface] }
        )
        #expect(downloader.existingModelFolder() == nil)
    }

    @Test func existingModelFolder_variantNameMismatch_returnsNil() throws {
        let base = try makeRepoDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let variantDir = base
            .appending(path: "models/argmaxinc/whisperkit-coreml/openai_whisper-tiny")
        try FileManager.default.createDirectory(
            at: variantDir.appending(path: "TextDecoder.mlmodelc"), withIntermediateDirectories: true
        )
        let downloader = WhisperKitModelDownloader(
            variantProvider: { "small" }, downloadBase: base, endpointChain: { [.huggingface] }
        )
        #expect(downloader.existingModelFolder() == nil)
    }
}

/// 模型激活失败自愈（"已就绪 + 永远 Speech"卡死修复：删残骸 + 每会话自动重试一次）
@MainActor
struct ModelInvalidationTests {

    private func settle() async {
        for _ in 0..<12 { await Task { @MainActor in }.value }
    }

    @Test func markInvalidModel_firstTime_deletesFolderAndAutoRetries() async {
        let downloader = MockModelDownloader()
        downloader.existingFolder = URL(fileURLWithPath: "/tmp")
        let manager = ModelDownloadManager(downloader: downloader)
        #expect(manager.state == .ready)

        manager.markInvalidModel(reason: "模型文件不完整")

        // 自愈前置：删除被调用（mock 模拟目录已删）
        #expect(downloader.removeInvalidModelCallCount == 1)
        #expect(downloader.existingFolder == nil)
        // 自动重试已启动（failed 是瞬态，立即进入 downloading）
        guard case .downloading = manager.state else {
            Issue.record("期望 downloading（自动重试中），实际 \(manager.state)")
            return
        }

        await settle()
        #expect(manager.state == .ready) // 重试成功恢复
        #expect(downloader.downloadCallCount == 1)
    }

    @Test func markInvalidModel_secondFailure_noAutoRetryButManualRetryWorks() async {
        let downloader = MockModelDownloader()
        downloader.existingFolder = URL(fileURLWithPath: "/tmp")
        downloader.downloadError = NSError(
            domain: "mock", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "模拟下载失败"]
        )
        let manager = ModelDownloadManager(downloader: downloader)

        // 第一次：删目录 + 自动重试，重试也失败 → failed
        manager.markInvalidModel(reason: "模型文件不完整")
        await settle()
        guard case .failed = manager.state else {
            Issue.record("期望 failed（自动重试失败），实际 \(manager.state)")
            return
        }
        #expect(downloader.downloadCallCount == 1)

        // 第二次激活失败：自动重试已用尽，停 failed 态
        manager.markInvalidModel(reason: "模型文件不完整，请在设置中重试下载")
        await settle()
        #expect(downloader.downloadCallCount == 1)
        guard case .failed(let message) = manager.state else {
            Issue.record("期望保持 failed，实际 \(manager.state)")
            return
        }
        #expect(message.contains("重试"))
        // failed 态引擎解析落 Speech（无激活循环）
        #expect(TranscriptionEngineResolver.resolve(setting: "whisperkit", modelReady: manager.state.isReady) == .speech)

        // 手动重试（设置页按钮）仍可用
        downloader.downloadError = nil
        manager.startDownloadIfNeeded()
        await settle()
        #expect(downloader.downloadCallCount == 2)
        #expect(manager.state == .ready)
    }
}

/// 引擎路由器（运行时切换）
@MainActor
struct TranscriptionEngineRouterTests {

    @Test func router_forwardsToCurrentAndSwitches() async throws {
        let speech = MockTranscriptionEngine()
        speech.result = "系统识别结果"
        let whisper = MockTranscriptionEngine()
        whisper.result = "本地模型结果"

        let router = TranscriptionEngineRouter(current: speech)
        #expect(router.name == "mock")

        var text = try await router.transcribe(samples: [0.1])
        #expect(text == "系统识别结果")

        router.use(whisper) // 模型就绪后切换
        text = try await router.transcribe(samples: [0.1])
        #expect(text == "本地模型结果")
        #expect(whisper.callCount == 1)
        #expect(speech.callCount == 1)
    }
}
