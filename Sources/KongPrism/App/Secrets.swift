import Foundation
import Security

/// Subscription links (they carry account tokens) and the GitHub token live in the login
/// keychain instead of the JSON files in Application Support, which backup and sync tools copy
/// in plain text.
///
/// Only for a build signed with a Developer ID (a Team ID): macOS ties keychain items to the
/// signer's partition ("teamid:…"), and an ad-hoc signed build gets a new identity with every
/// update, so each update would ask for the login password before it could read its own link.
/// CI showed exactly that (another binary could not read the item without a prompt), so ad-hoc
/// builds — the current releases — keep the links in profiles.json (permissions 600) as before.
enum Secrets {
    /// True when this copy of KongPrism is signed with a Team ID.
    static let useKeychain: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return false }
        return (dictionary[kSecCodeInfoTeamIdentifier as String] as? String).map { !$0.isEmpty } ?? false
    }()

    static var storageDescription: String {
        useKeychain ? "订阅链接和 GitHub 令牌保存在钥匙串里"
            : "订阅链接和 GitHub 令牌保存在本机文件里（只有你的账户可读）；这一版没有开发者 ID 签名，改存钥匙串会让每次更新后都要求输入登录密码"
    }

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
        guard useKeychain else { return profiles.map { var copy = $0; copy.urlInKeychain = nil; return copy } }
        return profiles.map { profile in
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
        guard useKeychain else { copy.githubTokenInKeychain = false; return copy }
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
