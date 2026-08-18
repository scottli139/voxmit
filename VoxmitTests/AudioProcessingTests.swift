import AVFoundation
import Foundation
import Testing
@testable import Voxmit

/// 电平换算（FR-A2）
struct AudioLevelMeterTests {

    @Test func rms_constantHalfAmplitude_isHalf() {
        #expect(AudioLevelMeter.rms([Float](repeating: 0.5, count: 100)) == 0.5)
        #expect(AudioLevelMeter.rms([]) == 0)
    }

    @Test func decibels_fullScale_isZero() {
        #expect(AudioLevelMeter.decibelsFullScale(rms: 1.0) == 0)
    }

    @Test func decibels_halfAmplitude_aboutMinus6dB() {
        // 0.5 振幅 ≈ -6.02 dBFS
        #expect(abs(AudioLevelMeter.decibelsFullScale(rms: 0.5) - (-6.0206)) < 0.001)
    }

    @Test func decibels_silenceAndTiny_floorClamped() {
        #expect(AudioLevelMeter.decibelsFullScale(rms: 0) == AudioLevelMeter.floor)
        #expect(AudioLevelMeter.decibelsFullScale(rms: 1e-9) == AudioLevelMeter.floor)
    }
}

/// 静音前缀裁剪（§4.2.2）
struct SilenceTrimmerTests {

    @Test func trim_leadingSilence_trimsToOnsetWithPadding() {
        // 200ms 静音 + 100ms 有效信号（16kHz）
        let samples = [Float](repeating: 0, count: 3200) + [Float](repeating: 0.5, count: 1600)
        let trimmed = SilenceTrimmer.trimLeadingSilence(samples)

        // 命中点后保留 50ms（800 样本）前导：3200 - 800 = 2400 处开剪
        #expect(trimmed.count == 4800 - 2400)
        #expect(trimmed.prefix(800).allSatisfy { $0 == 0 }) // 前导静音保留
        #expect(trimmed.suffix(1600).allSatisfy { $0 == 0.5 })
    }

    @Test func trim_allSilence_returnsEmpty() {
        #expect(SilenceTrimmer.trimLeadingSilence([Float](repeating: 0, count: 4800)).isEmpty)
    }

    @Test func trim_loudFromStart_unchanged() {
        let samples = [Float](repeating: 0.5, count: 1600)
        #expect(SilenceTrimmer.trimLeadingSilence(samples) == samples)
    }

    @Test func trim_belowThreshold_treatedAsSilence() {
        // 阈值 -45dBFS ≈ 振幅 0.0056；0.003 全程低于阈值
        #expect(SilenceTrimmer.trimLeadingSilence([Float](repeating: 0.003, count: 4800)).isEmpty)
        // 0.01 高于阈值：不裁
        let above = [Float](repeating: 0.01, count: 1600)
        #expect(SilenceTrimmer.trimLeadingSilence(above) == above)
    }

    @Test func trim_shortBuffer_underOneFrame_stillDetected() {
        let samples = [Float](repeating: 0.5, count: 80) // 不足一帧（160）
        #expect(SilenceTrimmer.trimLeadingSilence(samples) == samples)
    }
}

/// PCM 重采样（离线转换，无需硬件/权限）
struct PCMResamplerTests {

    private func makeBuffer(
        sampleRate: Double, channels: UInt32, frames: Int, amplitude: Float = 0.5
    ) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<Int(channels) {
            let data = buffer.floatChannelData![ch]
            for i in 0..<frames {
                data[i] = amplitude * sin(Float(i) * 0.1)
            }
        }
        return buffer
    }

    @Test func convert_48kStereo_to16kMonoFloat32() throws {
        let input = try #require(makeBuffer(sampleRate: 48000, channels: 2, frames: 4800))
        let resampler = try #require(PCMResampler(from: input.format))

        let output = try #require(resampler.convert(input))

        #expect(output.format.sampleRate == 16000)
        #expect(output.format.channelCount == 1)
        #expect(output.format.commonFormat == .pcmFormatFloat32)
        // 比率 1/3 → 期望约 1600 帧；AVAudioConverter SRC 有 ~10–15ms 启动延迟（实测缺口
        // 恒定、不随流增长，对秒级录音可忽略），容忍 ±300
        #expect(abs(Int(output.frameLength) - 1600) < 300)
    }

    @Test func convert_streaming_secondBufferContinues() throws {
        let input = try #require(makeBuffer(sampleRate: 48000, channels: 2, frames: 4800))
        let resampler = try #require(PCMResampler(from: input.format))

        let first = try #require(resampler.convert(input))
        let second = try #require(resampler.convert(input))

        // 流式累计 ≈ 3200 帧（启动延迟缺口只在起步体现一次，实测约 176 帧）
        let total = Int(first.frameLength) + Int(second.frameLength)
        #expect(abs(total - 3200) < 300)
        #expect(second.frameLength > first.frameLength) // 第二块起进入稳态
    }

    @Test func convert_sameFormat_ratioOne() throws {
        let input = try #require(makeBuffer(sampleRate: 16000, channels: 1, frames: 1600))
        let resampler = try #require(PCMResampler(from: input.format))

        let output = try #require(resampler.convert(input))

        #expect(abs(Int(output.frameLength) - 1600) < 50)
    }

    @Test func convert_emptyBuffer_returnsNil() throws {
        let input = try #require(makeBuffer(sampleRate: 48000, channels: 2, frames: 4800))
        let resampler = try #require(PCMResampler(from: input.format))
        input.frameLength = 0

        #expect(resampler.convert(input) == nil)
    }
}

/// 输入设备选择决策（FR-A1）
struct InputDeviceResolverTests {

    @Test func resolve_unconfigured_usesSystemDefault() {
        let result = InputDeviceResolver.resolve(configuredUID: nil, availableUIDs: ["a", "b"])
        #expect(result.uid == nil)
        #expect(!result.fellBackToDefault)
    }

    @Test func resolve_configuredAndAvailable_usesConfigured() {
        let result = InputDeviceResolver.resolve(configuredUID: "a", availableUIDs: ["a", "b"])
        #expect(result.uid == "a")
        #expect(!result.fellBackToDefault)
    }

    @Test func resolve_configuredButDisconnected_fallsBackToDefault() {
        let result = InputDeviceResolver.resolve(configuredUID: "gone", availableUIDs: ["a", "b"])
        #expect(result.uid == nil)
        #expect(result.fellBackToDefault)
    }

    @Test func resolve_configuredButNoDevicesAtAll_fallsBackToDefault() {
        let result = InputDeviceResolver.resolve(configuredUID: "gone", availableUIDs: [])
        #expect(result.uid == nil)
        #expect(result.fellBackToDefault)
    }
}

/// 5 分钟上限看门狗（FR-A3，MockClock 虚拟时间）
struct MaxDurationWatchdogTests {

    /// 线程安全标志（看门狗回调在协作线程池触发）
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _fired = false
        var fired: Bool { lock.withLock { _fired } }
        func set() { lock.withLock { _fired = true } }
    }

    @Test func watchdog_reachesLimit_firesOnce() async {
        let clock = MockClock()
        let watchdog = MaxDurationWatchdog(limit: 300, clock: clock)
        let flag = Flag()
        watchdog.onLimitReached = { flag.set() }

        watchdog.start()
        clock.advance(by: 299)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!flag.fired) // 未到点

        clock.advance(by: 1)
        // 回调经池线程 hop，轮询等待（预算 500ms，正常微秒级到达）
        for _ in 0..<50 where !flag.fired {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(flag.fired)
    }

    @Test func watchdog_stoppedBeforeLimit_doesNotFire() async {
        let clock = MockClock()
        let watchdog = MaxDurationWatchdog(limit: 300, clock: clock)
        let flag = Flag()
        watchdog.onLimitReached = { flag.set() }

        watchdog.start()
        clock.advance(by: 100)
        watchdog.stop()
        clock.advance(by: 300)

        try? await Task.sleep(for: .milliseconds(50))
        #expect(!flag.fired)
    }

    @Test func watchdog_restart_resetsTimer() async {
        let clock = MockClock()
        let watchdog = MaxDurationWatchdog(limit: 300, clock: clock)
        let flag = Flag()
        watchdog.onLimitReached = { flag.set() }

        watchdog.start()
        clock.advance(by: 200)
        watchdog.start() // 重新开始：旧计时作废
        clock.advance(by: 200) // 距重启仅 200s < 300
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!flag.fired)

        clock.advance(by: 100)
        for _ in 0..<50 where !flag.fired {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(flag.fired)
    }
}
