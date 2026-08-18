import Foundation
import WhisperKit

/// WhisperKit 模型下载（ModelDownloading 实装）：用 WhisperKit 内置静态下载
/// （swift-transformers Downloader 自带断点续传与 Progress 回调），
/// 落盘到 Application Support/Voxmit/Models（.gitignore 已排除模型文件）。
struct WhisperKitModelDownloader: ModelDownloading {
    /// 模型变体（asr.modelVariant：tiny / small / large-v3），读取时机为每次调用
    private let variantProvider: @Sendable () -> String
    private let downloadBase: URL

    init(variantProvider: @escaping @Sendable () -> String, downloadBase: URL) {
        self.variantProvider = variantProvider
        self.downloadBase = downloadBase
    }

    /// HubApi.localRepoLocation 约定（swift-transformers Hub）：downloadBase/models/<org>/<repo>
    private var repoDirectory: URL {
        downloadBase.appending(path: "models/argmaxinc/whisperkit-coreml", directoryHint: .isDirectory)
    }

    func existingModelFolder() -> URL? {
        let variant = variantProvider()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: repoDirectory, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return nil }
        return entries.first { url in
            guard url.lastPathComponent.localizedCaseInsensitiveContains(variant),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path),
                  !contents.isEmpty
            else { return false }
            return true
        }
    }

    func download(progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        try await WhisperKit.download(
            variant: variantProvider(),
            downloadBase: downloadBase,
            useBackgroundSession: true, // 后台下载（§4.2.3）
            progressCallback: { p in
                progress(p.fractionCompleted)
            }
        )
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
