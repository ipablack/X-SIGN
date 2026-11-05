import Foundation

// Bundle matching is a preflight check; the native signer still verifies the signing identity.
struct XSignProvisioningProfile: Sendable {
    let bundlePattern: String
    let expiration: Date
    var isWildcard: Bool { bundlePattern.hasSuffix("*") }

    enum ProfileError: LocalizedError {
        case malformed, expired, unsupportedBundle, mismatch
        var errorDescription: String? {
            switch self {
            case .malformed: return "تعذّر قراءة App ID من ملف البروفايل."
            case .expired: return "ملف البروفايل منتهي الصلاحية. اختر شهادة أخرى."
            case .unsupportedBundle: return "صيغة App ID في الشهادة غير مدعومة للمطابقة."
            case .mismatch: return "بندل التطبيق لا يطابق نطاق البروفايل. عدّل البندل أو اختر شهادة مناسبة."
            }
        }
    }

    static func read(at url: URL) throws -> Self {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 8_388_608 else { throw ProfileError.malformed }
        return try decode(Data(contentsOf: url, options: .mappedIfSafe))
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 8_388_608 else { throw ProfileError.malformed }
        let plist: Data
        if data.starts(with: Data("bplist".utf8)) { plist = data }
        else {
            guard let start = data.range(of: Data("<?xml".utf8)),
                  let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { throw ProfileError.malformed }
            plist = data.subdata(in: start.lowerBound..<end.upperBound)
        }
        guard let root = (try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil)) as? [String: Any],
              let entitlements = root["Entitlements"] as? [String: Any],
              let applicationID = entitlements["application-identifier"] as? String ?? entitlements["com.apple.application-identifier"] as? String,
              let expiration = root["ExpirationDate"] as? Date else { throw ProfileError.malformed }
        let prefixes = (root["ApplicationIdentifierPrefix"] as? [String] ?? []) + (root["TeamIdentifier"] as? [String] ?? [])
        guard let prefix = prefixes.filter({ !$0.isEmpty }).first(where: { applicationID.hasPrefix($0 + ".") }) else { throw ProfileError.malformed }
        let pattern = String(applicationID.dropFirst(prefix.count + 1))
        guard !pattern.isEmpty,
              pattern.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.*").contains($0) }),
              !pattern.contains(".."),
              !pattern.contains("*") || pattern == "*" || (pattern.hasSuffix(".*") && pattern.filter({ $0 == "*" }).count == 1) else { throw ProfileError.unsupportedBundle }
        return Self(bundlePattern: pattern, expiration: expiration)
    }

    func identifier(for current: String, matchExactID: Bool, now: Date = Date()) throws -> String {
        guard expiration > now else { throw ProfileError.expired }
        if isWildcard {
            let prefix = String(bundlePattern.dropLast())
            guard !current.isEmpty, current.hasPrefix(prefix), current.count > prefix.count else { throw ProfileError.mismatch }
            return current
        }
        if matchExactID { return bundlePattern }
        guard current == bundlePattern else { throw ProfileError.mismatch }
        return current
    }
}
