import SwiftUI

/// 设置页骨架（Phase 0）：分区对应需求文档 §9.2 设置项清单。
/// 仅负责设置值的读写与展示，各功能的实际接线在对应 Phase 完成。
struct SettingsView: View {
    // 通用
    @AppStorage(SettingsKeys.appLaunchAtLogin) private var launchAtLogin = false
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

    @State private var apiKeyInput = ""
    @State private var hasSavedAPIKey = KeychainHelper.readAPIKey() != nil

    var body: some View {
        Form {
            Section("通用") {
                // SMAppService.mainApp 接线在后续 Phase 实现（FR-G1），此处仅保存开关值
                Toggle("登录时启动", isOn: $launchAtLogin)
            }
            Section("音频") {
                // 占位：输入设备枚举与选择随 AudioCapture（Phase 3）实现，当前固定使用系统默认设备
                LabeledContent("输入设备", value: "系统默认")
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
    SettingsView()
}
