import AVFoundation
import Foundation
import Speech

enum SpeechEngineError: LocalizedError, Equatable {
    case recognizerUnavailable
    case permissionDenied
    case bufferCreationFailed
    /// 系统级听写被关闭（系统设置 → 键盘 → 听写）；权限已授权但识别服务不可用
    case dictationDisabled
    /// SFSpeechRecognizer(locale:) 返回 nil：系统不支持该语言标识
    case localeUnsupported(String)
    /// 端侧听写语言资产缺失：听写语言列表未添加对应语言（requiresOnDeviceRecognition 下识别必败）
    case onDeviceLanguageMissing(String)

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable: return "系统语音识别不可用"
        case .permissionDenied: return "未授予语音识别权限"
        case .bufferCreationFailed: return "音频缓冲创建失败"
        case .dictationDisabled:
            return "Speech 兜底不可用：请在 系统设置 → 键盘 → 听写 中开启听写（或等待 WhisperKit 模型下载完成）"
        case .localeUnsupported(let locale):
            return "Speech 兜底不支持该语言（\(locale)）：可将 asr.speechLocale 改为 zh-CN（或等待 WhisperKit 模型下载完成）"
        case .onDeviceLanguageMissing(let locale):
            return "Speech 兜底需要本地听写语言（\(locale)）：系统设置 → 键盘 → 听写 → 语言 中添加（或等待 WhisperKit 模型下载完成）"
        }
    }
}

/// Speech 识别语言解析（纯逻辑可单测）：设置键 asr.speechLocale，默认 zh-CN
/// （本产品主场景中文口述 + 夹英文术语；WhisperKit 天然中英混识不受此限）。
/// 空串/空白回退默认；语言有效性由 SFSpeechRecognizer 初始化与端侧资产检查兜底。
enum SpeechLocaleResolver {
    static let fallback = "zh-CN"

    static func resolve(setting: String?) -> String {
        let raw = (setting ?? fallback).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? fallback : raw
    }
}

/// Speech 错误映射（纯逻辑可单测）："Siri and Dictation are disabled" 来自运行时
/// AssistantServices（SDK 无公开错误码），按"错误域含 Assistant + 文案含 Dictation"识别；
/// 其余错误原样透传
enum SpeechErrorMapper {
    static func map(_ error: Error) -> Error {
        let nsError = error as NSError
        if nsError.domain.contains("Assistant"),
           nsError.localizedDescription.contains("Dictation") {
            return SpeechEngineError.dictationDisabled
        }
        return error
    }
}

/// Speech 框架兜底引擎（§4.2.3：模型下载完成前自动使用；端侧识别 requiresOnDeviceRecognition）
///
/// 注意：语音识别是独立于麦克风的第四个 TCC 权限（首次使用系统弹窗），
/// 需求文档 §4.4 权限矩阵未列——兜底引擎仅在用到时请求。
final class SpeechTranscriptionEngine: TranscriptionEngine, @unchecked Sendable {
    let name = "speech"

    func transcribe(samples: [Float]) async throws -> String {
        // 空音频/纯静音 → 空串（§4.2.3）
        guard !samples.isEmpty else { return "" }

        // 识别语言（asr.speechLocale，默认 zh-CN；WhisperKit 中英混识不受此限）
        let localeID = SpeechLocaleResolver.resolve(
            setting: UserDefaults.standard.string(forKey: SettingsKeys.asrSpeechLocale)
        )
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else {
            AppLog.error(.transcription, "Speech 不支持该语言：\(localeID)")
            throw SpeechEngineError.localeUnsupported(localeID)
        }
        guard recognizer.isAvailable else {
            throw SpeechEngineError.recognizerUnavailable
        }
        // 端侧听写语言资产缺失（听写语言列表未添加该语言）：端侧强制下识别必败，提前给出可操作文案
        guard recognizer.supportsOnDeviceRecognition else {
            AppLog.error(.transcription, "端侧听写语言资产缺失：\(localeID)")
            throw SpeechEngineError.onDeviceLanguageMissing(localeID)
        }

        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            AppLog.notice(.transcription, "语音识别授权结果：\(SFSpeechRecognizer.authorizationStatus().rawValue)")
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            AppLog.error(.transcription, "语音识别权限被拒，Speech 兜底不可用")
            throw SpeechEngineError.permissionDenied
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioConstants.sampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw SpeechEngineError.bufferCreationFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            if let baseAddress = ptr.baseAddress {
                buffer.floatChannelData![0].update(from: baseAddress, count: samples.count)
            }
        }

        return try await recognize(recognizer: recognizer, buffer: buffer)
    }

    private func recognize(recognizer: SFSpeechRecognizer, buffer: AVAudioPCMBuffer) async throws -> String {
        // 识别回调可能多次返回（错误/最终结果竞态），保证 continuation 单次 resume
        final class ResumeGuard: @unchecked Sendable {
            private let lock = NSLock()
            private var resumed = false
            func tryResume() -> Bool {
                lock.withLock {
                    if resumed { return false }
                    resumed = true
                    return true
                }
            }
        }
        final class TaskBox: @unchecked Sendable {
            private let lock = NSLock()
            private var task: SFSpeechRecognitionTask?
            func set(_ task: SFSpeechRecognitionTask) { lock.withLock { self.task = task } }
            func cancel() { lock.withLock { task }?.cancel() }
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        let resumeGuard = ResumeGuard()
        let taskBox = TaskBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let task = recognizer.recognitionTask(with: request) { result, error in
                    // Esc 取消传播：Pipeline 期望 CancellationError 走 cancelled 路径
                    if Task.isCancelled {
                        if resumeGuard.tryResume() { continuation.resume(throwing: CancellationError()) }
                        return
                    }
                    if let error {
                        // 听写关闭等可识别错误映射为用户可操作文案（SpeechErrorMapper）
                        if resumeGuard.tryResume() {
                            continuation.resume(throwing: SpeechErrorMapper.map(error))
                        }
                        return
                    }
                    if let result, result.isFinal {
                        if resumeGuard.tryResume() {
                            continuation.resume(returning: result.bestTranscription.formattedString)
                        }
                    }
                }
                taskBox.set(task)
                request.append(buffer)
                request.endAudio()
            }
        } onCancel: {
            taskBox.cancel()
        }
    }
}
