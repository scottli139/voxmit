import Foundation

/// UserDefaults 设置键清单与默认值（需求文档 §9.2）
///
/// API Key 不进 UserDefaults，只存 Keychain（见 KeychainHelper）。
enum SettingsKeys {
    static let hotkeyKeyCode = "hotkey.keyCode"
    static let hotkeyBypassModifier = "hotkey.bypassModifier"
    static let audioInputDeviceUID = "audio.inputDeviceUID"
    static let audioPlaySounds = "audio.playSounds"
    static let asrEngine = "asr.engine"
    static let asrModelVariant = "asr.modelVariant"
    static let asrCustomVocabulary = "asr.customVocabulary"
    /// 模型仓库端点策略（unset/"auto"=官方优先失败回退镜像 / "huggingface" / "hf-mirror"；无设置页 UI）
    static let asrModelRepoEndpoint = "asr.modelRepoEndpoint"
    /// Speech 兜底引擎识别语言（默认 zh-CN：主场景中文口述+夹英文术语；无设置页 UI）
    static let asrSpeechLocale = "asr.speechLocale"
    /// WhisperKit 转写语言锁定（默认 "zh" 锁中文：短音频自动检测不可靠；"auto" = 自动检测；无设置页 UI）
    static let asrWhisperLanguage = "asr.whisperLanguage"
    static let llmBaseURL = "llm.baseURL"
    static let llmModel = "llm.model"
    static let llmRefineEnabled = "llm.refineEnabled"
    /// 润色隐私告知已确认（§4.2.4 首次启用弹窗；确认后不再弹）
    static let llmPrivacyAcknowledged = "llm.privacyAcknowledged"
    static let injectAutoSend = "inject.autoSend"
    static let injectCollapseNewlines = "inject.collapseNewlines"
    static let historyLimit = "history.limit"
    static let historyRetentionDays = "history.retentionDays"
    static let appLaunchAtLogin = "app.launchAtLogin"
    /// 首次启动权限引导是否已完成（FR-G5；§9.2 之外的 App 内部标记）
    static let appOnboardingCompleted = "app.onboardingCompleted"

    /// 注册 §9.2 默认值（register 仅在键缺失时生效，不覆盖用户已修改的值）。
    ///
    /// `audio.inputDeviceUID` 默认 nil（系统默认设备），不注册，缺省即视为系统默认。
    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            hotkeyKeyCode: 0x3D,             // 右 Option（kVK_RightOption）
            hotkeyBypassModifier: 0x38,      // Shift（kVK_Shift），FR-D4 旁路修饰键
            audioPlaySounds: true,
            asrEngine: "whisperkit",
            asrModelVariant: "small",
            asrCustomVocabulary: [String](),
            asrModelRepoEndpoint: "auto",
            asrSpeechLocale: "zh-CN",
            asrWhisperLanguage: "zh",
            llmBaseURL: "https://api.moonshot.cn/v1",
            llmModel: "moonshot-v1-8k",      // Moonshot 模型 ID，按服务商文档可改
            llmRefineEnabled: true,
            llmPrivacyAcknowledged: false,
            injectAutoSend: false,           // FR-F4，默认关
            injectCollapseNewlines: true,    // CLI 目标默认折叠换行，适配层可按 App 覆盖
            historyLimit: 500,
            historyRetentionDays: 30,
            appLaunchAtLogin: false,
            appOnboardingCompleted: false,
        ])
    }
}
