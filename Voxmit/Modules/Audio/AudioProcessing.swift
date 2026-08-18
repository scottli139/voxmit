import AVFoundation
import Foundation

// 音频纯逻辑层：电平换算、静音前缀裁剪、PCM 重采样、输入设备选择决策。
// 全部无硬件/权限依赖，可单测（docs/TESTING.md）；engine 交互在 AudioCapture.swift。

/// 目标采样率（需求文档 §4.2.2：16kHz 单声道 Float32 PCM）
enum AudioConstants {
    static let sampleRate: Double = 16_000
}

/// 实时电平（FR-A2）：RMS → dBFS，供 HUD 波形
enum AudioLevelMeter {
    /// 电平窗口：50ms @16kHz（§4.2.2）
    static let windowSize = 800

    /// dBFS 下限（静音地板）
    static let floor: Float = -120

    /// 均方根；空输入返回 0
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// RMS → dBFS（20·log10），钳制到 [floor, 0]
    static func decibelsFullScale(rms: Float) -> Float {
        guard rms > 0 else { return floor }
        return min(0, max(floor, 20 * log10(rms)))
    }

    static func decibelsFullScale(samples: [Float]) -> Float {
        decibelsFullScale(rms: rms(samples))
    }
}

/// 静音前缀裁剪（§4.2.2 边界情况）：蓝牙麦连接协商延迟会在开头产生百毫秒级空数据，
/// 转写前裁掉，避免无效识别与幻觉文本
enum SilenceTrimmer {
    /// 判定阈值：-45 dBFS（≈ 振幅 0.0056）。工程取值：低于常见环境底噪（-60dB 以下）之上、
    /// 明显低于正常说话电平（-20dB 上下）；推导见 docs/implementation-notes.md
    static let thresholdDecibels: Float = -45

    /// 检测窗口：10ms @16kHz
    static let frameSize = 160

    /// 命中点后保留的前导长度（50ms），避免切掉辅音起音
    static let keepLeadingSamples = 800

    /// 裁剪前导静音；全静音返回空数组（上游按"空音频"静默结束，§4.2.3）
    static func trimLeadingSilence(_ samples: [Float]) -> [Float] {
        let threshold = pow(10, thresholdDecibels / 20)
        var index = 0
        while index + frameSize <= samples.count {
            var peak: Float = 0
            for i in index..<(index + frameSize) {
                peak = max(peak, abs(samples[i]))
            }
            if peak >= threshold {
                let cut = max(0, index - keepLeadingSamples)
                return cut == 0 ? samples : Array(samples[cut...])
            }
            index += frameSize
        }
        // 末尾不足一帧的尾巴也检查一次
        if index < samples.count {
            var peak: Float = 0
            for i in index..<samples.count {
                peak = max(peak, abs(samples[i]))
            }
            if peak >= threshold {
                let cut = max(0, index - keepLeadingSamples)
                return cut == 0 ? samples : Array(samples[cut...])
            }
        }
        return []
    }
}

/// PCM 重采样（§4.2.2）：任意硬件格式 → 16kHz 单声道 Float32。
/// 包装 AVAudioConverter 的流式用法（保持转换状态，可连续喂多块）；
/// 离线缓冲转换不需要硬件/权限，可直接单测。
/// 非线程安全：调用方保证单线程串行调用（生产为 audio tap 回调线程，测试为调用线程）。
final class PCMResampler {
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(from inputFormat: AVAudioFormat, sampleRate: Double = AudioConstants.sampleRate) {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.converter = converter
    }

    /// 转换一块输入缓冲；失败返回 nil（调用方丢弃该块，不中断录音）
    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard input.frameLength > 0 else { return nil }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }
        var error: NSError?
        var consumed = false
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            // 单块输入一次性提供；二次索取时声明 noDataNow
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        switch status {
        case .haveData, .endOfStream:
            return output
        case .error:
            return nil
        case .inputRanDry:
            return output.frameLength > 0 ? output : nil
        @unknown default:
            return nil
        }
    }
}

/// 输入设备选择决策（FR-A1；纯逻辑可单测）
enum InputDeviceResolver {
    /// - 未配置 → nil（跟随系统默认）
    /// - 已配置且当前可用 → 该 UID
    /// - 已配置但已断开 → nil（回落系统默认）+ fellBackToDefault = true（HUD 提示用）
    static func resolve(
        configuredUID: String?,
        availableUIDs: [String]
    ) -> (uid: String?, fellBackToDefault: Bool) {
        guard let configuredUID else { return (nil, false) }
        if availableUIDs.contains(configuredUID) {
            return (configuredUID, false)
        }
        return (nil, true)
    }
}
