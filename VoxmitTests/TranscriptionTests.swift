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
