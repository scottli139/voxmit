import Foundation
import Security

/// LLM API Key 的 Keychain 存取（需求文档 §9.2）
///
/// kSecClassGenericPassword，service = bundle identifier，account = "llm-api-key"，
/// 访问策略 kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly（不随备份/迁移出本机）。
///
/// 读结果带进程内内存缓存：ad-hoc 开发构建的签名随每次构建变化，Keychain ACL 的
/// 「始终允许」无法持久化信任，每次 SecItem 调用都会弹授权窗（且一次调用可能连弹多个，
/// 见 docs/implementation-notes.md「Keychain 反复弹授权窗」）。缓存后会话内只真实读一次，
/// 弹窗合并到启动期（启动时的设置快照日志即触发），润色的 3s 预算不被 Keychain 阻塞。
enum KeychainHelper {
    private static let account = "llm-api-key"

    private static var service: String {
        Bundle.main.bundleIdentifier ?? "com.voxmit.app"
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// 读取缓存：nil = 尚未真实读取；.some(nil) = 已确认未保存；.some(key) = 命中。
    /// 锁串行化并发首次读取，避免多线程同时触发多个授权弹窗（Swift 6：@unchecked Sendable 收敛可变状态）
    private final class KeyCache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String??

        /// 命中直接返回；未命中执行一次真实读取并缓存结果（含「确认未保存」的 nil）
        func read(orReadKeychain readKeychain: () -> String?) -> String? {
            lock.withLock {
                if let value { return value }
                let key = readKeychain()
                value = key
                return key
            }
        }

        func update(_ key: String?) {
            lock.withLock { value = key }
        }
    }

    private static let cache = KeyCache()

    /// 保存 API Key；已存在时走 SecItemUpdate 更新；成功时同步内存缓存
    ///
    /// 注意：SecItemUpdate 只改数据不改 ACL——旧构建创建的条目对当前构建仍是不可信的。
    /// 想消除弹窗需删除条目后由当前构建重新 SecItemAdd（创建者天然被信任）。
    @discardableResult
    static func saveAPIKey(_ key: String) -> Bool {
        let data = Data(key.utf8)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        var status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(baseQuery as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else { return false }
        cache.update(key)
        return true
    }

    /// 读取 API Key；未保存时返回 nil。会话内只真实访问一次 Keychain（见文件头注释）
    static func readAPIKey() -> String? {
        cache.read {
            var query = baseQuery
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    /// 删除已保存的 API Key；成功时同步内存缓存
    @discardableResult
    static func deleteAPIKey() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { return false }
        cache.update(nil)
        return true
    }
}
