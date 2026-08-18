import Foundation
import WhisperKit

/// 模型目录就绪校验（纯逻辑可单测；真机踩坑：官方端点超时遗留的残骸目录曾被误判就绪，
/// 幂等下载短路 + 激活失败兜底叠加成"已就绪但永远 Speech"卡死，详见 implementation-notes）
///
/// 校验强度对齐"激活成功的必要条件"：whisperkit-coreml 全变体（tiny/small/large-v3）同构，
/// 变体目录内必须同时存在 config.json 与三个 Core ML 目录包（缺一即不完整）。
enum ModelFolderValidator {
    /// 必需文件
    static let requiredFiles = ["config.json"]
    /// 必需目录包（Core ML 编译产物）
    static let requiredPackages = ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"]

    static func isReady(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        for name in requiredFiles {
            var isDirectory: ObjCBool = false
            let path = url.appending(path: name).path
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { return false }
        }
        for name in requiredPackages {
            var isDirectory: ObjCBool = false
            let path = url.appending(path: name).path
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { return false }
        }
        return true
    }
}

/// WhisperKit 模型下载（ModelDownloading 实装）：用 WhisperKit 内置静态下载
/// （swift-transformers Downloader 自带断点续传与 Progress 回调——incomplete 文件按本地
/// 路径记录、与端点域名无关，镜像回退后续传仍有效），落盘 Application Support/Voxmit/Models。
///
/// 端点回退：按 endpointChain 顺序逐端点尝试（默认官方 → 镜像），单端点失败记录后尝试下一个；
/// 用户取消（CancellationError）不回退直接抛出。
struct WhisperKitModelDownloader: ModelDownloading {
    /// 单端点下载执行点（默认 WhisperKit 内置静态下载；单测注入 mock，禁真实网络）。
    /// `useBackgroundSession`：后台传输（nsurlsessiond）优先，调用方在 -997 时回退前台
    typealias DownloadExecutor = @Sendable (
        _ variant: String,
        _ endpoint: ModelRepoEndpoint,
        _ downloadBase: URL,
        _ useBackgroundSession: Bool,
        _ progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL

    /// 模型变体（asr.modelVariant：tiny / small / large-v3），读取时机为每次调用
    private let variantProvider: @Sendable () -> String
    private let downloadBase: URL
    /// 端点尝试顺序（asr.modelRepoEndpoint 设置，读取时机为每次下载）
    private let endpointChain: @Sendable () -> [ModelRepoEndpoint]
    private let executeDownload: DownloadExecutor

    init(
        variantProvider: @escaping @Sendable () -> String,
        downloadBase: URL,
        endpointChain: @escaping @Sendable () -> [ModelRepoEndpoint],
        executeDownload: @escaping DownloadExecutor = Self.downloadWithWhisperKit
    ) {
        self.variantProvider = variantProvider
        self.downloadBase = downloadBase
        self.endpointChain = endpointChain
        self.executeDownload = executeDownload
    }

    /// 真实下载执行点：WhisperKit 内置（HubApi 支持自定义 endpoint；HF_ENDPOINT 环境变量亦可）
    static func downloadWithWhisperKit(
        variant: String,
        endpoint: ModelRepoEndpoint,
        downloadBase: URL,
        useBackgroundSession: Bool,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        try await WhisperKit.download(
            variant: variant,
            downloadBase: downloadBase,
            useBackgroundSession: useBackgroundSession,
            endpoint: endpoint.rawValue,
            progressCallback: { p in
                progress(p.fractionCompleted)
            }
        )
    }

    /// 后台传输服务（nsurlsessiond）不可用判定：NSURLErrorDomain -997
    /// （NSURLErrorBackgroundSessionWasDisconnected，错误描述为 Lost connection to
    /// background transfer service），按错误码判定、不匹配文案
    static func isLostBackgroundTransferConnection(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == NSURLErrorBackgroundSessionWasDisconnected
    }

    /// HubApi.localRepoLocation 约定（swift-transformers Hub）：downloadBase/models/<org>/<repo>
    private var repoDirectory: URL {
        downloadBase.appending(path: "models/argmaxinc/whisperkit-coreml", directoryHint: .isDirectory)
    }

    /// 按名匹配的所有变体目录（不做就绪校验——自愈删除要能命中残骸）
    private func variantDirectories() -> [URL] {
        let variant = variantProvider()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: repoDirectory, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return entries.filter { url in
            url.lastPathComponent.localizedCaseInsensitiveContains(variant)
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    func existingModelFolder() -> URL? {
        // 就绪校验：完整产物集（ModelFolderValidator），残骸不算
        variantDirectories().first { ModelFolderValidator.isReady($0) }
    }

    /// 自愈前置：删除按名匹配的所有变体目录（不完整/损坏产物），强制干净重下
    /// （否则 Downloader 认为文件已完整会跳过，重试永远拿到同一份坏文件）。
    /// 删除失败不阻塞状态回退。
    func removeInvalidModel() {
        for url in variantDirectories() {
            try? FileManager.default.removeItem(at: url)
            AppLog.notice(.download, "已删除不完整模型目录：\(url.lastPathComponent)")
        }
    }

    func download(progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        let variant = variantProvider()
        var failures: [EndpointFailure] = []
        for endpoint in endpointChain() {
            do {
                return try await downloadOnEndpoint(endpoint, variant: variant, progress: progress)
            } catch is CancellationError {
                throw CancellationError() // 用户取消不回退
            } catch {
                failures.append(EndpointFailure(endpoint: endpoint.rawValue, reason: error.localizedDescription))
            }
        }
        throw ModelDownloadError.allEndpointsFailed(failures)
    }

    /// 单端点下载：先后台 session；后台传输服务不可用（-997）时同端点回退前台一次。
    /// 回退在端点循环之内，不影响端点间回退顺序；前台 session 的断点续传仍由
    /// incomplete 文件机制保证（跨启动不受影响）。
    private func downloadOnEndpoint(
        _ endpoint: ModelRepoEndpoint,
        variant: String,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        do {
            AppLog.info(.download, "模型下载开始：\(variant)，端点 \(endpoint.rawValue)，后台 session")
            let folder = try await executeDownload(variant, endpoint, downloadBase, true, progress)
            AppLog.info(.download, "模型下载完成：\(folder.lastPathComponent)（端点 \(endpoint.rawValue)，后台）")
            return folder
        } catch is CancellationError {
            AppLog.notice(.download, "模型下载被取消")
            throw CancellationError()
        } catch {
            guard Self.isLostBackgroundTransferConnection(error) else {
                AppLog.error(.download, "端点 \(endpoint.rawValue) 下载失败：\(error.localizedDescription)")
                throw error
            }
            AppLog.notice(.download, "后台传输服务不可用（-997），同端点回退前台 session")
            AppLog.info(.download, "模型下载开始：\(variant)，端点 \(endpoint.rawValue)，前台 session")
            let folder = try await executeDownload(variant, endpoint, downloadBase, false, progress)
            AppLog.info(.download, "模型下载完成：\(folder.lastPathComponent)（端点 \(endpoint.rawValue)，前台）")
            return folder
        }
    }
}

enum WhisperKitEngineError: LocalizedError {
    case modelNotReady

    var errorDescription: String? { "WhisperKit 模型未就绪" }
}

/// WhisperKit 引擎（FR-C1 默认引擎）：模型就绪后激活（loadModels 加载到内存），
/// 转写重计算由 WhisperKit 内部线程执行。
final class WhisperKitTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    let name = "whisperkit"

    private let modelFolderProvider: @Sendable () async -> URL?
    private let lock = NSLock()
    private var kit: WhisperKit?
    /// 已加载模型对应的目录（变体切换后需重载）
    private var loadedFolder: URL?
    private var activationTask: Task<Void, Error>?
    /// activationTask 对应的目标目录
    private var pendingFolder: URL?

    init(modelFolderProvider: @escaping @Sendable () async -> URL?) {
        self.modelFolderProvider = modelFolderProvider
    }

    /// 激活（幂等、并发去重）：加载模型到内存；模型目录变化（变体切换）时重新加载；
    /// 失败抛错（调用方保持 Speech 兜底）
    func activate() async throws {
        guard let folder = await modelFolderProvider() else {
            throw WhisperKitEngineError.modelNotReady
        }
        if lock.withLock({ kit != nil && loadedFolder == folder }) { return }
        let task: Task<Void, Error> = lock.withLock {
            if let activationTask, pendingFolder == folder { return activationTask }
            let newTask = Task { [weak self] in
                guard let self else { throw WhisperKitEngineError.modelNotReady }
                AppLog.info(.transcription, "WhisperKit 模型加载中：\(folder.lastPathComponent)")
                let startedAt = Date()
                let config = WhisperKitConfig(
                    modelFolder: folder.path,
                    verbose: false,
                    logLevel: .error,
                    download: false
                )
                let loaded = try await WhisperKit(config)
                try await loaded.loadModels()
                lock.withLock {
                    self.kit = loaded
                    self.loadedFolder = folder
                }
                let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                AppLog.info(.transcription, "WhisperKit 模型加载完成，耗时 \(milliseconds)ms")
            }
            activationTask = newTask
            pendingFolder = folder
            return newTask
        }
        try await task.value
    }

    func transcribe(samples: [Float]) async throws -> String {
        // 空音频/纯静音 → 空串（§4.2.3，Pipeline 按误触静默结束）
        guard !samples.isEmpty else { return "" }
        try await activate()
        guard let kit = lock.withLock({ self.kit }) else {
            throw WhisperKitEngineError.modelNotReady
        }
        let results = try await kit.transcribe(audioArray: samples)
        return results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
