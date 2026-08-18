import AVFoundation
import Foundation
import Speech

enum SpeechEngineError: LocalizedError {
    case recognizerUnavailable
    case onDeviceUnsupported
    case permissionDenied
    case bufferCreationFailed

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable: return "系统语音识别不可用"
        case .onDeviceUnsupported: return "当前设备不支持端侧语音识别"
        case .permissionDenied: return "未授予语音识别权限"
        case .bufferCreationFailed: return "音频缓冲创建失败"
        }
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

        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw SpeechEngineError.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw SpeechEngineError.onDeviceUnsupported
        }

        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
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
                        if resumeGuard.tryResume() { continuation.resume(throwing: error) }
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
