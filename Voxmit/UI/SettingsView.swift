import SwiftUI

/// 设置页骨架（Phase 0）：分区对应需求文档 §9.2 设置项清单。
/// 仅负责设置值的读写与展示，各功能的实际接线在对应 Phase 完成。
struct SettingsView: View {
    /// 模型下载状态（Phase 5 转写区展示）
    @ObservedObject var modelDownloadManager: ModelDownloadManager
    /// 当前生效引擎展示
    @ObservedObject var transcriptionRouter: TranscriptionEngineRouter
    // 通用
    @AppStorage(SettingsKeys.appLaunchAtLogin) private var launchAtLogin = false
    // 热键
    @AppStorage(SettingsKeys.hotkeyKeyCode) private var hotkeyKeyCode = 0x3D
    // 转写
    @AppStorage(SettingsKeys.asrEngine) private var asrEngine = "whisperkit"
    @AppStorage(SettingsKeys.asrModelVariant) private var asrModelVariant = "small"
    // LLM
    @AppStorage(SettingsKeys.llmBaseURL) private var llmBaseURL = "https://api.moonshot.cn/v1"
    @AppStorage(SettingsKeys.llmModel) private var llmModel = "moonshot-v1-8k"
    @AppStorage(SettingsKeys.llmRefineEnabled) private var llmRefineEnabled = true
    // 注入
    @AppStorage(SettingsKeys.injectAutoSend) private var injectAutoSend = false
    @AppStorage(SettingsKeys.injectCollapseNewlines) private var injectCollapseNewlines = true
    @AppStorage(SettingsKeys.audioInputDeviceUID) private var inputDeviceUID: String?

    @State private var apiKeyInput = ""
    @State private var hasSavedAPIKey = KeychainHelper.readAPIKey() != nil
    /// 可用输入设备列表（每次打开设置页时查询）
    @State private var inputDevices: [InputDeviceInfo] = []

    /// 选择绑定：空串 ↔ nil（nil = 跟随系统默认设备）
    private var inputDeviceSelection: Binding<String> {
        Binding(
            get: { inputDeviceUID ?? "" },
            set: { inputDeviceUID = $0.isEmpty ? nil : $0 }
        )
    }

    /// 模型下载状态区（FR-C1：small 约 500MB，后台下载 + 断点续传 + 落盘校验）
    @ViewBuilder
    private var modelStatusView: some View {
        switch modelDownloadManager.state {
        case .notStarted:
            Text("本地模型未下载；下载完成前由 Speech（系统）兜底转写")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .downloading(let progress):
            HStack {
                ProgressView(value: progress)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("正在下载本地模型（small 约 500MB，可断点续传）…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .ready:
            Text("本地模型已就绪")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            HStack {
                Text("模型下载失败：\(message)")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("重试") {
                    modelDownloadManager.startDownloadIfNeeded()
                }
            }
        }
    }

    var body: some View {
        Form {
            Section("通用") {
                // SMAppService.mainApp 接线在后续 Phase 实现（FR-G1），此处仅保存开关值
                Toggle("登录时启动", isOn: $launchAtLogin)
            }
            Section("热键") {
                // FR-B2 的 MVP 版：预设四档，改动即时生效（HotkeyManager 监听 hotkey.keyCode）
                Picker("按住说话的热键", selection: $hotkeyKeyCode) {
                    ForEach(HotkeyPreset.allCases, id: \.keyCode) { preset in
                        Text(preset.displayName).tag(Int(preset.keyCode))
                    }
                }
                if hotkeyKeyCode == Int(HotkeyPreset.rightShift.keyCode) {
                    // 热键与旁路修饰键同为 Shift：旁路判定自动禁用，避免每次录音都跳过润色
                    Text("热键为右 Shift 时，旁路修饰键（Shift）判定自动禁用")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("与其他 App 快捷键冲突时可在此更换；完整自定义录入（任意组合键）将在 V1.1 提供")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("音频") {
                Picker("输入设备", selection: inputDeviceSelection) {
                    Text("系统默认").tag("")
                    ForEach(inputDevices, id: \.uid) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .onAppear {
                    inputDevices = InputDeviceCatalog.currentInputDevices()
                }
                // 提示音开关（FR-A4）为 P1，随 V1.1 接线
            }
            Section("转写") {
                Picker("引擎", selection: $asrEngine) {
                    Text("WhisperKit（本地）").tag("whisperkit")
                    Text("Speech（系统）").tag("speech")
                    Text("云端").tag("cloud")
                }
                Picker("模型", selection: $asrModelVariant) {
                    Text("tiny").tag("tiny")
                    Text("small").tag("small")
                    Text("large-v3").tag("large-v3")
                }
                // 当前生效引擎：模型未就绪/未下载时 Speech 兜底（§4.2.3）
                LabeledContent(
                    "当前引擎",
                    value: transcriptionRouter.current.name == "whisperkit" ? "WhisperKit（本地）" : "Speech（系统）"
                )
                modelStatusView
            }
            Section("LLM 润色") {
                Toggle("启用润色（关闭后全局直出原文）", isOn: $llmRefineEnabled)
                TextField("Base URL", text: $llmBaseURL)
                TextField("模型", text: $llmModel)
                HStack {
                    SecureField("API Key", text: $apiKeyInput)
                    Button("保存") {
                        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !key.isEmpty else { return }
                        if KeychainHelper.saveAPIKey(key) {
                            apiKeyInput = ""
                            hasSavedAPIKey = true
                        }
                    }
                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if hasSavedAPIKey {
                    Text("已保存，输入以替换")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("注入") {
                Toggle("粘贴后自动发送（Return）", isOn: $injectAutoSend)
                Toggle("多行文本折叠为一行（CLI 目标）", isOn: $injectCollapseNewlines)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 500)
    }
}

#Preview {
    // 预览用真实实例（init 无副作用：不下载、不识别）
    let speech = SpeechTranscriptionEngine()
    return SettingsView(
        modelDownloadManager: ModelDownloadManager(
            downloader: WhisperKitModelDownloader(
                variantProvider: { "small" },
                downloadBase: VoxmitAppDelegate.modelsDirectory
            )
        ),
        transcriptionRouter: TranscriptionEngineRouter(current: speech)
    )
}
