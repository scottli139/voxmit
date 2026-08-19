import AppKit
import Combine

/// App 级协调器：持有 VoicePipeline 与 PermissionManager，
/// 负责首次启动权限引导判定（FR-G5）与权限快照向 Pipeline 的实时同步。
///
/// 通过 `@NSApplicationDelegateAdaptor` 挂到 SwiftUI App 生命周期（见 VoxmitApp）。
@MainActor
final class VoxmitAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let permissionManager = PermissionManager()
    /// 音频采集（Phase 3 实装）；注入 Pipeline 替换 Phase 2 的 NoOp 占位
    let audioCapture = AudioCapture(maxDuration: VoicePipeline.maximumRecordingDuration)
    /// lazy：依赖 audioCapture 与转写路由器，且避免 @MainActor 类显式 override init 的隔离问题
    private(set) lazy var pipeline = VoicePipeline(
        audio: audioCapture,
        transcription: transcriptionRouter
    )

    /// 权限自检引导窗口；完成（含「跳过，降级运行」）时写入 UserDefaults 标记
    private lazy var onboardingController = PermissionOnboardingWindowController(
        permissionManager: permissionManager,
        onFinish: {
            UserDefaults.standard.set(true, forKey: SettingsKeys.appOnboardingCompleted)
        }
    )

    /// 权限快照同步订阅（随 App 生命周期存活）
    private var permissionSync: AnyCancellable?

    /// 全局热键（FR-B1/FR-B5）；按输入监控权限自动启停，无权限时菜单降级入口可用
    private lazy var hotkeyManager = HotkeyManager(permissionManager: permissionManager)

    /// 录音 HUD（Phase 4）：非激活面板，不抢焦点；多 Space/全屏可见
    private lazy var hudController = RecordingHUDController(pipeline: pipeline, audioCapture: audioCapture)

    // MARK: - 转写（Phase 5：FR-C1）

    /// 模型存放目录：Application Support/Voxmit/Models（模型文件已被 .gitignore 排除）
    static var modelsDirectory: URL {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Voxmit/Models", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 模型下载管理器（small ≈ 500MB；变体随 asr.modelVariant 设置；端点策略随 asr.modelRepoEndpoint）
    private(set) lazy var modelDownloadManager = ModelDownloadManager(
        downloader: WhisperKitModelDownloader(
            variantProvider: { UserDefaults.standard.string(forKey: SettingsKeys.asrModelVariant) ?? "small" },
            downloadBase: Self.modelsDirectory,
            endpointChain: {
                ModelRepoEndpointResolver.attemptOrder(
                    setting: UserDefaults.standard.string(forKey: SettingsKeys.asrModelRepoEndpoint)
                )
            }
        )
    )

    /// Speech 框架兜底引擎（模型就绪前/显式选择时）
    private let speechEngine = SpeechTranscriptionEngine()

    /// WhisperKit 引擎（模型就绪后激活）
    private(set) lazy var whisperKitEngine = WhisperKitTranscriptionEngine(
        modelFolderProvider: { [weak self] in await self?.modelDownloadManager.modelFolder },
        downloadBase: Self.modelsDirectory
    )

    /// 引擎路由器：Pipeline 持有的稳定引用，运行时热切换
    private(set) lazy var transcriptionRouter = TranscriptionEngineRouter(current: speechEngine)

    /// 诊断日志导出（设置页「诊断」区）
    private(set) lazy var diagnosticExporter = DiagnosticLogExporter(permissionManager: permissionManager)

    /// 引擎切换观察（模型就绪/设置变更）
    private var engineStateCancellable: AnyCancellable?
    private var engineDefaultsObserver: (any NSObjectProtocol)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单测以 App 为宿主运行（TEST_HOST）：不弹引导窗口、不做权限同步接线，
        // 保证测试不依赖真实权限状态（docs/TESTING.md）
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        AppLog.info(.app, "Voxmit 启动完成（版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知")）")

        // 权限快照实时同步给 Pipeline（降级决策数据源，需求文档 §4.4）
        permissionSync = permissionManager.$snapshot.sink { [pipeline] snapshot in
            Task { @MainActor in
                pipeline.applyPermissionSnapshot(snapshot)
            }
        }

        // 热键事件 → 状态机（§4.2.0：HotkeyManager 只上报原始事件，时序判定在 Pipeline）
        hotkeyManager.onHotkeyDown = { [pipeline] bypass in
            pipeline.handleHotkeyDown(bypassModifierActive: bypass)
        }
        hotkeyManager.onHotkeyUp = { [pipeline] in pipeline.handleHotkeyUp() }
        hotkeyManager.onEscape = { [pipeline] in pipeline.cancel() }
        _ = hotkeyManager // 触发 lazy 创建，开始按权限状态监听

        // 5 分钟录音上限（FR-A3）：AudioCapture 计时，到点走"松手"流程
        audioCapture.onMaxDurationReached = { [pipeline] in
            Task { @MainActor in pipeline.handleMaxRecordingDuration() }
        }

        // 录音 HUD：订阅状态机与电平，自动出现/隐藏
        _ = hudController

        // 转写引擎（Phase 5）：按"设置 + 模型就绪"路由（模型未就绪时 Speech 兜底，§4.2.3），
        // 并后台启动模型下载（断点续传，~500MB）
        recomputeTranscriptionEngine()
        modelDownloadManager.startDownloadIfNeeded()
        engineStateCancellable = modelDownloadManager.$state.sink { [weak self] _ in
            Task { @MainActor in self?.recomputeTranscriptionEngine() }
        }
        engineDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // 引擎/模型规格变更：重估就绪状态并按需重启下载
                self?.modelDownloadManager.reevaluate()
                self?.recomputeTranscriptionEngine()
                self?.modelDownloadManager.startDownloadIfNeeded()
            }
        }

        // 首次启动且权限未集齐 → 自动展示权限自检页（§4.4：麦克风 → 输入监控 → 辅助功能）
        let completed = UserDefaults.standard.bool(forKey: SettingsKeys.appOnboardingCompleted)
        if PermissionManager.shouldPresentOnboarding(
            hasCompletedOnboarding: completed,
            snapshot: permissionManager.snapshot
        ) {
            showPermissionOnboarding()
        }
    }

    /// 菜单栏「权限自检…」入口
    func showPermissionOnboarding() {
        permissionManager.refresh()
        onboardingController.show()
    }

    /// 引擎路由决策（TranscriptionEngineResolver 纯逻辑）：whisperkit 需模型就绪并先激活，
    /// 激活失败保持 Speech 兜底
    private func recomputeTranscriptionEngine() {
        let setting = UserDefaults.standard.string(forKey: SettingsKeys.asrEngine) ?? "whisperkit"
        let ready = modelDownloadManager.state.isReady
        switch TranscriptionEngineResolver.resolve(setting: setting, modelReady: ready) {
        case .speech:
            transcriptionRouter.use(speechEngine)
        case .whisperKit:
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await whisperKitEngine.activate()
                    transcriptionRouter.use(whisperKitEngine)
                } catch {
                    // 激活失败 = 目录在但模型不可加载（残骸/不完整）：保持 Speech 兜底，
                    // 并把下载状态打回 failed 以便设置页重试（failed 态 resolve 落 speech，
                    // 不会再次激活，无 catch→failed→recompute 循环）
                    AppLog.error(.transcription, "WhisperKit 激活失败，保持 Speech 兜底：\(error.localizedDescription)")
                    transcriptionRouter.use(speechEngine)
                    modelDownloadManager.markInvalidModel(reason: "模型文件不完整，请在设置中重试下载")
                }
            }
        }
    }
}
