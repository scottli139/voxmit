import AVFoundation
import Combine
import CoreAudio
import Foundation

/// AudioCapture 事件（提示 UI 在 Phase 4 消费；当前仅发布）
enum AudioCaptureEvent: Sendable, Equatable {
    /// 单次录音达 5 分钟上限（FR-A3，提示"已达最长录音时长"）
    case maxDurationReached
    /// 用户指定的输入设备已断开，回落系统默认设备（§4.2.2）
    case inputDeviceFellBackToDefault
    /// 采集中断（如最后一个输入设备被拔出）；已录部分保留（§4.2.2）
    case captureInterrupted
}

/// 音频采集错误（§4.2.2：权限被拒 / 无输入设备 → 抛错，Pipeline 走 failed）
enum AudioCaptureError: LocalizedError, Equatable {
    case microphonePermissionDenied
    case noInputDevice
    case converterUnavailable
    case engineStartFailed

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied: return "未授予麦克风权限"
        case .noInputDevice: return "未检测到可用输入设备"
        case .converterUnavailable: return "音频格式转换不可用"
        case .engineStartFailed: return "音频引擎启动失败"
        }
    }
}

/// 5 分钟录音上限看门狗（FR-A3）：独立组件，时钟注入可单测。
/// 回调在协作线程池触发，接收方自行切换执行上下文。
final class MaxDurationWatchdog: @unchecked Sendable {
    private let limit: TimeInterval
    private let clock: any PipelineClock
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    /// 到点回调（@Sendable：可能在非主线程触发）
    var onLimitReached: (@Sendable () -> Void)?

    init(limit: TimeInterval, clock: any PipelineClock) {
        self.limit = limit
        self.clock = clock
    }

    func start() {
        stop()
        let startedAt = clock.now
        let newTask = Task { [weak self] in
            guard let self else { return }
            do {
                // 截止锚定在 start() 调用时刻（而非任务首次被调度的时刻），
                // 虚拟时钟测试与真实运行语义一致
                let remaining = limit - clock.now.timeIntervalSince(startedAt)
                try await clock.sleep(for: max(0, remaining))
            } catch {
                return // stop() 取消
            }
            if Task.isCancelled { return }
            let callback = lock.withLock { onLimitReached }
            callback?()
        }
        lock.withLock { task = newTask }
    }

    func stop() {
        let existing = lock.withLock { () -> Task<Void, Never>? in
            defer { task = nil }
            return task
        }
        existing?.cancel()
    }
}

/// 音频采集（需求文档 §4.2.2，FR-A1/A2/A3）
///
/// 线程模型：
/// - `start()` / `stop()` / `cancel()` 与 engine 重建约定**主线程**调用
///   （dispatchPrecondition 断言；VoicePipeline 为 @MainActor，天然满足）；
/// - tap 回调在**实时音频线程**：只做重采样 → 短临界区加锁追加样本 → 电平计算发布，
///   不分配大对象、不持锁调用外部代码；
/// - `samples` 缓冲由 NSLock 保护（音频线程追加、主线程 stop/cancel 读取清空）；
/// - `levels` / `events` 从音频线程或看门狗线程发布，订阅者需自行 `receive(on:)`。
final class AudioCapture: AudioCapturing, @unchecked Sendable {
    /// 实时电平（dBFS，约 50ms 一拍，FR-A2；Phase 4 HUD 波形消费）
    let levels = PassthroughSubject<Float, Never>()

    /// 事件发布（上限提示 / 设备回落 / 采集中断；Phase 4 提示 UI 消费）
    let events = PassthroughSubject<AudioCaptureEvent, Never>()

    /// 达 5 分钟上限的回调（VoxmitAppDelegate 接到 VoicePipeline.handleMaxRecordingDuration）
    var onMaxDurationReached: (@Sendable () -> Void)?

    private let inputDeviceUIDProvider: @Sendable () -> String?
    private let watchdog: MaxDurationWatchdog

    private let lock = NSLock()
    private var samples: [Float] = []
    private var levelSampleCounter = 0

    // 以下仅主线程访问（dispatchPrecondition 保护）
    private var engine: AVAudioEngine?
    private var resampler: PCMResampler?
    private var configChangeObserver: (any NSObjectProtocol)?

    init(
        clock: any PipelineClock = SystemPipelineClock(),
        maxDuration: TimeInterval = 300,
        inputDeviceUIDProvider: @escaping @Sendable () -> String? = {
            UserDefaults.standard.string(forKey: SettingsKeys.audioInputDeviceUID)
        }
    ) {
        self.watchdog = MaxDurationWatchdog(limit: maxDuration, clock: clock)
        self.inputDeviceUIDProvider = inputDeviceUIDProvider
        watchdog.onLimitReached = { [weak self] in
            self?.events.send(.maxDurationReached)
            self?.onMaxDurationReached?()
        }
    }

    // MARK: - AudioCapturing（主线程调用）

    func start() throws {
        dispatchPrecondition(condition: .onQueue(.main))

        // 麦克风权限（§4.2.2；正常路径已被 Pipeline 的 canRecord 门控，此处防御性检查）
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioCaptureError.microphonePermissionDenied
        }

        lock.withLock {
            samples.removeAll()
            levelSampleCounter = 0
        }

        try beginCapture()
        watchdog.start()
    }

    func stop() -> [Float] {
        dispatchPrecondition(condition: .onQueue(.main))
        watchdog.stop()
        teardownCapture()
        return lock.withLock {
            defer {
                samples.removeAll()
                levelSampleCounter = 0
            }
            return samples
        }
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        watchdog.stop()
        teardownCapture()
        lock.withLock {
            samples.removeAll()
            levelSampleCounter = 0
        }
    }

    // MARK: - engine 生命周期（主线程）

    /// 建立采集链路：设备选择 → 重采样器 → tap → 启动 engine。
    /// start() 与配置变更重建共用；重建时已录缓冲保留（§4.2.2）。
    private func beginCapture() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        // 输入设备选择（FR-A1）：指定设备有效则应用；已断开则回落系统默认并发事件
        let resolution = InputDeviceResolver.resolve(
            configuredUID: inputDeviceUIDProvider(),
            availableUIDs: InputDeviceCatalog.currentInputDevices().map(\.uid)
        )
        if let uid = resolution.uid,
           let deviceID = InputDeviceLookup.deviceID(forUID: uid),
           let audioUnit = input.audioUnit {
            var deviceID = deviceID
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }
        if resolution.fellBackToDefault {
            events.send(.inputDeviceFellBackToDefault)
        }

        guard let resampler = PCMResampler(from: hardwareFormat) else {
            throw AudioCaptureError.converterUnavailable
        }
        self.resampler = resampler

        input.installTap(onBus: 0, bufferSize: 4800, format: nil) { [weak self] buffer, _ in
            self?.handleTapBuffer(buffer)
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError.engineStartFailed
        }

        self.engine = engine
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            // 设备热切换（§4.2.2）：重建 engine 续录，已录缓冲保留
            self?.handleConfigurationChange()
        }
    }

    private func teardownCapture() {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
            self.configChangeObserver = nil
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        resampler = nil
    }

    private func handleConfigurationChange() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard engine != nil else { return }
        teardownCapture()
        do {
            try beginCapture()
        } catch {
            // 重建失败（如输入设备已全部断开）：发布中断事件，已录部分保留（§4.2.2）
            events.send(.captureInterrupted)
        }
    }

    // MARK: - tap 回调（实时音频线程）

    private func handleTapBuffer(_ buffer: AVAudioPCMBuffer) {
        // resampler 在 engine 启动前于主线程赋值，音频线程读取无竞态（先行发生关系由 engine.start 建立）
        guard let resampler,
              let converted = resampler.convert(buffer),
              converted.frameLength > 0,
              let channelData = converted.floatChannelData else {
            return
        }
        let chunk = Array(UnsafeBufferPointer(start: channelData[0], count: Int(converted.frameLength)))

        let window: [Float]? = lock.withLock {
            samples.append(contentsOf: chunk)
            levelSampleCounter += chunk.count
            guard levelSampleCounter >= AudioLevelMeter.windowSize else { return nil }
            levelSampleCounter = 0
            return Array(samples.suffix(AudioLevelMeter.windowSize))
        }
        // 电平发布在锁外（dBFS，FR-A2；约 50ms 一拍）
        if let window {
            levels.send(AudioLevelMeter.decibelsFullScale(samples: window))
        }
    }
}

/// 当前可用输入设备目录（AVCaptureDevice DiscoverySession；枚举设备不需要麦克风权限）
struct InputDeviceInfo: Equatable, Sendable {
    let uid: String
    let name: String
}

enum InputDeviceCatalog {
    static func currentInputDevices() -> [InputDeviceInfo] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.map { InputDeviceInfo(uid: $0.uniqueID, name: $0.localizedName) }
    }
}

/// CoreAudio 设备 UID → AudioDeviceID 查询（engine.inputNode 设设备只认 AudioDeviceID）
enum InputDeviceLookup {
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return nil }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.stride
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs
        ) == noErr else { return nil }

        for id in deviceIDs {
            if deviceUID(of: id) == uid { return id }
        }
        return nil
    }

    private static func deviceUID(of deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        // AudioObjectGetPropertyData 返回 +1 持有的 CF 对象，takeRetainedValue 平衡
        return value?.takeRetainedValue() as String?
    }
}
