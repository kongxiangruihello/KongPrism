import Foundation
import Security

/// Subscription links (they carry account tokens) and the GitHub token live in the login
/// keychain instead of the JSON files in Application Support, which backup and sync tools copy
/// in plain text.
///
/// KongPrism releases are ad-hoc signed, so every update has a different code signature. A
/// keychain item that trusts only "the app that created it" would make macOS ask for the login
/// password after every update. The items are therefore created with an access list that lets
/// any application read them without a prompt — the same reach as the files had, but encrypted
/// at rest and not copied around in plain text.
enum Secrets {
    static let service = "com.kongxiangrui.KongPrism"
    /// What is known to be in the keychain, so settings saves (frequent) do not touch it.
    private static var cache: [String: String] = [:]

    static func subscriptionAccount(_ id: UUID) -> String { "subscription:\(id.uuidString)" }
    static let githubAccount = "github-token"

    // MARK: Keychain

    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        if cache[account] == value { return true }
        delete(account)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "KongPrism（\(account.hasPrefix("subscription") ? "订阅链接" : "GitHub 令牌")）",
            kSecValueData as String: Data(value.utf8),
        ]
        if let access = anyApplicationAccess() { query[kSecAttrAccess as String] = access }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            AppLog.write("写入钥匙串失败（\(status)），继续保存在文件里")
            return false
        }
        cache[account] = value
        return true
    }

    static func get(_ account: String) -> String? {
        if let cached = cache[account] { return cached }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        cache[account] = value
        return value
    }

    static func delete(_ account: String) {
        cache[account] = nil
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// An access object whose entries allow any application without a prompt (see above).
    private static func anyApplicationAccess() -> SecAccess? {
        var access: SecAccess?
        guard SecAccessCreate("KongPrism" as CFString, [] as CFArray, &access) == errSecSuccess, let access else { return nil }
        guard let entries = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt) as? [SecACL] else { return access }
        for entry in entries {
            // A nil application list means any application may use the item.
            _ = SecACLSetContents(entry, nil, "KongPrism" as CFString, SecKeychainPromptSelector())
        }
        return access
    }

    // MARK: Files ↔ keychain

    /// The profiles as written to profiles.json: links moved to the keychain.
    static func forDisk(_ profiles: [Profile]) -> [Profile] {
        profiles.map { profile in
            var copy = profile
            guard let url = profile.url else { copy.urlInKeychain = nil; return copy }
            if set(url, account: subscriptionAccount(profile.id)) {
                copy.url = nil
                copy.urlInKeychain = true
            }
            return copy
        }
    }

    /// The profiles as read from profiles.json, links filled in from the keychain.
    static func restore(_ profiles: [Profile]) -> [Profile] {
        profiles.map { profile in
            var copy = profile
            if profile.urlInKeychain == true, profile.url == nil {
                copy.url = get(subscriptionAccount(profile.id))
                if copy.url == nil {
                    copy.lastError = "钥匙串里找不到这个订阅的链接，请在 设置 › 订阅 › 编辑… 里重新填写"
                    AppLog.write("钥匙串里找不到订阅“\(profile.name)”的链接")
                }
            }
            return copy
        }
    }

    static func forDisk(_ settings: AppSettings) -> AppSettings {
        var copy = settings
        if settings.githubToken.isEmpty {
            if settings.githubTokenInKeychain { delete(githubAccount) }
            copy.githubTokenInKeychain = false
        } else if set(settings.githubToken, account: githubAccount) {
            copy.githubToken = ""
            copy.githubTokenInKeychain = true
        }
        return copy
    }

    static func restore(_ settings: AppSettings) -> AppSettings {
        var copy = settings
        if settings.githubTokenInKeychain, settings.githubToken.isEmpty {
            copy.githubToken = get(githubAccount) ?? ""
        }
        return copy
    }
}
