import Foundation
import Testing
@testable import Voxmit

/// SettingsKeys 默认值注册（需求文档 §9.2）
struct SettingsStoreTests {

    @Test func registerDefaults_freshSuite_documentDefaults() throws {
        let suiteName = "com.voxmit.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SettingsKeys.registerDefaults(in: defaults)

        #expect(defaults.bool(forKey: SettingsKeys.injectAutoSend) == false)
        #expect(defaults.bool(forKey: SettingsKeys.llmRefineEnabled) == true)
        #expect(defaults.string(forKey: SettingsKeys.asrModelVariant) == "small")
        #expect(defaults.string(forKey: SettingsKeys.llmBaseURL) == "https://api.moonshot.cn/v1")
        #expect(defaults.integer(forKey: SettingsKeys.historyLimit) == 500)
        #expect(defaults.integer(forKey: SettingsKeys.hotkeyKeyCode) == 0x3D)
    }
}

/// VoicePipeline Phase 0 状态承载
struct VoicePipelineTests {

    @Test @MainActor func voicePipeline_initialState_idleWithWaveformIcon() {
        let pipeline = VoicePipeline()

        #expect(pipeline.menuBarIcon == "waveform")
        guard case .idle = pipeline.state else {
            Issue.record("初始状态应为 .idle，实际为 \(pipeline.state)")
            return
        }
    }
}
