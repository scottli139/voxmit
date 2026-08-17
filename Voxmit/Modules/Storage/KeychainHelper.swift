import Foundation
import Security

/// LLM API Key 的 Keychain 存取（需求文档 §9.2）
///
/// kSecClassGenericPassword，service = bundle identifier，account = "llm-api-key"，
/// 访问策略 kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly（不随备份/迁移出本机）。
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

    /// 保存 API Key；已存在时走 SecItemUpdate 更新
    @discardableResult
    static func saveAPIKey(_ key: String) -> Bool {
        let data = Data(key.utf8)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return SecItemUpdate(baseQuery as CFDictionary,
                                 [kSecValueData as String: data] as CFDictionary) == errSecSuccess
        }
        return status == errSecSuccess
    }

    /// 读取 API Key；未保存时返回 nil
    static func readAPIKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    /// 删除已保存的 API Key
    @discardableResult
    static func deleteAPIKey() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
