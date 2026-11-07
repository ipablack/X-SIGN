import Foundation

// Bundle matching is a preflight check; the native signer still verifies the signing identity.
struct XSignProvisioningProfile: Sendable {
    let bundlePattern: String
    let expiration: Date
    var isWildcard: Bool { bundlePattern.hasSuffix("*") }

    enum ProfileError: LocalizedError {
        case malformed, expired, unsupportedBundle, mismatch, batchCollision, protectedApplication
        var errorDescription: String? {
            switch self {
            case .malformed: return "تعذّر قراءة App ID من ملف البروفايل."
            case .expired: return "ملف البروفايل منتهي الصلاحية. اختر شهادة أخرى."
            case .unsupportedBundle: return "صيغة App ID في الشهادة غير مدعومة للمطابقة."
            case .mismatch: return "بندل التطبيق لا يطابق نطاق البروفايل. عدّل البندل أو اختر شهادة مناسبة."
            case .batchCollision: return "المطابقة اليدوية ستعطي التطبيقات بندلاً واحداً. احتفظ ببندلات التطبيقات المختلفة عند توقيع المجموعة."
            case .protectedApplication: return "هذه المطابقة ستستبدل XSign نفسه. اختر شهادة تقبل بندل التطبيق أو شهادة عامة مناسبة."
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

    // Strict verification remains strict. A different identifier is proposed
    // separately and applied only after explicit metadata-edit permission.
    func signingIdentifier(for current: String, allowRemap: Bool, metadataEditingAllowed: Bool,
                           preserveBatchIdentity: Bool = false, protectedIdentifier: String? = nil,
                           now: Date = Date()) throws -> String {
        guard expiration > now else { throw ProfileError.expired }
        do { return try identifier(for: current, matchExactID: false, now: now) }
        catch ProfileError.mismatch {
            guard metadataEditingAllowed else { throw ProfileError.mismatch }
            if preserveBatchIdentity && !isWildcard { throw ProfileError.batchCollision }
            let replacement: String
            if isWildcard {
                let prefix = String(bundlePattern.dropLast())
                replacement = prefix + current
            } else {
                replacement = bundlePattern
            }
            if replacement == protectedIdentifier { throw ProfileError.protectedApplication }
            guard current.utf8.count <= 255,
                  current.range(of: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*$", options: .regularExpression) != nil,
                  Self.validIdentifier(replacement) else { throw ProfileError.unsupportedBundle }
            _ = try identifier(for: replacement, matchExactID: false, now: now)
            guard allowRemap else { throw XSignProfileIdentityChange(current: current, replacement: replacement) }
            return replacement
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value.utf8.count <= 255 && value.range(of: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil
    }
}

struct XSignProfileIdentityChange: LocalizedError, Sendable {
    let current: String
    let replacement: String
    var errorDescription: String? {
        "الشهادة لا تقبل البندل الحالي: \(current)\nيمكن توقيع نسخة ببندل متوافق: \(replacement)\nتغيير البندل قد يؤثر في بيانات التطبيق وخدماته. وقد يستبدل التثبيت تطبيقاً يستخدم البندل الجديد."
    }
}
