import Foundation
import Security

/// Credentials stay outside SQLite, exports and complete-learning archives.
/// This device-only keychain item is available after the first unlock for optional night analysis.
enum AICoachKeychain {
    static let service = "biz.powerunion.iword.ai-coach"
    private static let account = "configuration-v1"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func load() throws -> AICoachConfiguration? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else {
            throw ContentFailure(message: "AI配置暂时无法读取，请解锁手机后重试。")
        }
        guard data.count < 64 * 1024 else { throw ContentFailure(message: "本地AI配置无效，请重新更新配置。") }
        do {
            let configuration = try JSONDecoder().decode(AICoachConfiguration.self, from: data)
            try configuration.validate()
            return configuration
        } catch { throw ContentFailure(message: "本地AI配置无效，请重新更新配置。") }
    }
    static func save(_ configuration: AICoachConfiguration) throws {
        try configuration.validate()
        let data = try JSONEncoder().encode(configuration)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            for (key, value) in attributes { item[key] = value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw ContentFailure(message: "AI配置未能安全保存，原配置保持不变。")
            }
        } else if status != errSecSuccess {
            throw ContentFailure(message: "AI配置未能安全保存，原配置保持不变。")
        }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ContentFailure(message: "未能删除本机AI配置，请解锁手机后重试。")
        }
    }
}
