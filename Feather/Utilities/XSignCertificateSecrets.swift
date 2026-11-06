import Foundation
import Security

// Imported P12 passwords are never persisted in Core Data, URLs, logs or HTTP.
enum XSignCertificateSecrets {
    static let marker = "xsign:keychain-password:v1"
    private static var service: String { (Bundle.main.bundleIdentifier ?? "XSign") + ".signing-password.v1" }

    private static func query(_ uuid: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: uuid, kSecAttrSynchronizable as String: false]
    }
    static func save(_ password: String, uuid: String) throws {
        let base = query(uuid)
        let attributes: [String: Any] = [kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(base.merging(attributes) { _, value in value } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }
    static func read(uuid: String) throws -> String {
        var request = query(uuid)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw failure(status)
        }
        return password
    }
    static func delete(uuid: String) { SecItemDelete(query(uuid) as CFDictionary) }
    static func deleteAll() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
    private static func failure(_ status: OSStatus) -> NSError {
        NSError(domain: "XSign.Keychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey:
            "تعذّر الوصول إلى كلمة مرور الشهادة المحمية. افتح قفل الجهاز أو أعد استيراد الشهادة."])
    }
}
