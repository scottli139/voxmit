import AppKit
import SwiftUI

@main
struct VoxmitApp: App {
    @StateObject private var pipeline = VoicePipeline()

    init() {
        // 注册需求文档 §9.2 设置项默认值（register 仅在键缺失时生效，不覆盖用户已修改的值）
        SettingsKeys.registerDefaults()
    }

    var body: some Scene {
        MenuBarExtra {
            Text(pipeline.statusText)
            Divider()
            SettingsLink {
                Text("设置…")
            }
            Divider()
            Button("退出 Voxmit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(systemName: pipeline.menuBarIcon)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
        }
    }
}
