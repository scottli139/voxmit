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

/// WhisperKit 模型下载（ModelDownloading 实装）：2026-08-18 起用自实现 `ModelRepoDownloader`
/// （弃用 WhisperKit.download 的根因见 implementation-notes「HF 端点回退」与下载器章节），
/// 落盘 Application Support/Voxmit/Models。
///
/// 端点回退：按 endpointChain 顺序逐端点尝试（默认官方 → 镜像），单端点失败记录后尝试下一个；
/// 用户取消（CancellationError）不回退直接抛出。
struct WhisperKitModelDownloader: ModelDownloading {
    /// 单端点下载执行点（默认自实现 ModelRepoDownloader；单测注入 mock，禁真实网络）
    typealias DownloadExecutor = @Sendable (
        _ variant: String,
        _ endpoint: ModelRepoEndpoint,
        _ downloadBase: URL,
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
        executeDownload: @escaping DownloadExecutor = Self.downloadWithRepoDownloader
    ) {
        self.variantProvider = variantProvider
        self.downloadBase = downloadBase
        self.endpointChain = endpointChain
        self.executeDownload = executeDownload
    }

    /// 真实下载执行点：自实现 ModelRepoDownloader（前台 URLSession，清单/续传/校验/移动）
    static func downloadWithRepoDownloader(
        variant: String,
        endpoint: ModelRepoEndpoint,
        downloadBase: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        try await ModelRepoDownloader(client: URLSessionRepoHTTPClient())
            .download(variant: variant, endpoint: endpoint.rawValue, downloadBase: downloadBase, progress: progress)
    }

    /// HubApi.localRepoLocation 约定（与自实现下载器一致）：downloadBase/models/<org>/<repo>
    private var repoDirectory: URL {
        downloadBase.appending(path: "models/argmaxinc/whisperkit-coreml", directoryHint: .isDirectory)
    }

    /// 按名匹配的所有变体目录
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

    func download(progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        let variant = variantProvider()
        var failures: [EndpointFailure] = []
        for endpoint in endpointChain() {
            do {
                AppLog.info(.download, "模型下载开始：\(variant)，端点 \(endpoint.rawValue)")
                let folder = try await executeDownload(variant, endpoint, downloadBase, progress)
                AppLog.info(.download, "模型下载完成：\(folder.lastPathComponent)（端点 \(endpoint.rawValue)）")
                return folder
            } catch is CancellationError {
                AppLog.notice(.download, "模型下载被取消")
                throw CancellationError() // 用户取消不回退
            } catch {
                AppLog.error(.download, "端点 \(endpoint.rawValue) 下载失败：\(error.localizedDescription)")
                failures.append(EndpointFailure(endpoint: endpoint.rawValue, reason: error.localizedDescription))
            }
        }
        throw ModelDownloadError.allEndpointsFailed(failures)
    }
}

enum WhisperKitEngineError: LocalizedError {
    case modelNotReady

    var errorDescription: String? { "WhisperKit 模型未就绪" }
}

/// Whisper 转写语言锁定解析（纯逻辑可单测）：设置键 asr.whisperLanguage。
/// 默认 "zh" 锁中文——短音频自动语言检测不可靠（真机：2 秒重复音节被误判英文）；
/// 锁中文后中英文混识不受影响（纯英文音频仍转英文，只是检测不再摇摆）。
/// "auto" 恢复自动检测（传 nil）；其余值原样透传（DecodingOptions.language 取
/// ISO 639-1 码，如 "zh"/"en"，见 WhisperKit Constants.languageCodes）。
enum WhisperLanguageResolver {
    static let fallback = "zh"

    static func resolve(setting: String?) -> String? {
        let raw = (setting ?? fallback).trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return fallback }
        return raw.lowercased() == "auto" ? nil : raw
    }
}

/// WhisperKit 引擎（FR-C1 默认引擎）：模型就绪后激活（loadModels 加载到内存），
/// 转写重计算由 WhisperKit 内部线程执行。
final class WhisperKitTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    let name = "whisperkit"

    private let modelFolderProvider: @Sendable () async -> URL?
    /// tokenizer 搜索基准目录（WhisperKitConfig.downloadBase；我们的 Models 目录）
    private let downloadBase: URL
    private let lock = NSLock()
    private var kit: WhisperKit?
    /// 已加载模型对应的目录（变体切换后需重载）
    private var loadedFolder: URL?
    private var activationTask: Task<Void, Error>?
    /// activationTask 对应的目标目录
    private var pendingFolder: URL?

    init(
        modelFolderProvider: @escaping @Sendable () async -> URL?,
        downloadBase: URL
    ) {
        self.modelFolderProvider = modelFolderProvider
        self.downloadBase = downloadBase
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
                    downloadBase: downloadBase, // tokenizer 搜索路径锚定我们的 Models 目录
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
        // 语言锁定（asr.whisperLanguage，默认 zh；auto 恢复自动检测）
        let language = WhisperLanguageResolver.resolve(
            setting: UserDefaults.standard.string(forKey: SettingsKeys.asrWhisperLanguage)
        )
        AppLog.info(.transcription, "WhisperKit 转写开始：\(samples.count) 样本（≈\(samples.count / 16000) 秒），language=\(language ?? "auto")")
        let results = try await kit.transcribe(
            audioArray: samples,
            decodeOptions: DecodingOptions(language: language)
        )
        return results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
