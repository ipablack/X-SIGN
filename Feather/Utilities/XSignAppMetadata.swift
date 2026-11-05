import Foundation

enum XSignAppMetadata {
    enum Field: Equatable, Sendable { case name, bundleIdentifier, version }

    nonisolated static func archiveFileName(name: String?, version: String?, suffix: String) -> String {
        func component(_ value: String?, fallback: String, maxBytes: Int) -> String {
            let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
            let clean = (value ?? "").components(separatedBy: invalid).joined(separator: "_")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
            var result = ""
            for character in clean {
                if result.utf8.count + String(character).utf8.count > maxBytes { break }
                result.append(character)
            }
            return result.isEmpty ? fallback : result
        }
        return component(name, fallback: "XSign", maxBytes: 120) + "_" + component(version, fallback: "1.0", maxBytes: 40)
            + "_" + component(suffix, fallback: "export", maxBytes: 40) + ".ipa"
    }

    nonisolated static func readInfo(at url: URL) throws -> NSMutableDictionary {
        let data = try Data(contentsOf: url)
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw NSError(domain: "XSign.Metadata", code: 400, userInfo: [NSLocalizedDescriptionKey: "ملف معلومات التطبيق أو الصلاحيات غير صالح."])
        }
        return NSMutableDictionary(dictionary: dictionary)
    }


    nonisolated static func editingAllowed(_ explicitPermission: Bool?) -> Bool {
        // A legacy rename lock must not disable the newly supported metadata editor.
        explicitPermission ?? true
    }

    nonisolated static func errorMessage(for value: String, field: Field) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "أدخل قيمة أو استخدم القيمة الأصلية." }
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return "القيمة تحتوي على محارف غير صالحة."
        }
        switch field {
        case .name:
            return value.count <= 255 ? nil : "اسم التطبيق طويل جدًا."
        case .bundleIdentifier:
            guard value.utf8.count <= 255,
                  value.range(of: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil else {
                return "استخدم بندل مثل com.example.app بحروف إنجليزية وأرقام وشرطات ونقاط."
            }
            return nil
        case .version:
            return value.range(of: "^[0-9]+(?:\\.[0-9]+){0,2}$", options: .regularExpression) != nil
                ? nil : "اكتب الإصدار بالأرقام مثل 2.0 أو 2.0.1."
        }
    }

    nonisolated static func validated(_ value: String?, field: Field, original: String?) throws -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean == original { return nil }
        if let message = errorMessage(for: clean, field: field) {
            throw NSError(domain: "XSign.AppMetadata", code: 400, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return clean
    }

    nonisolated static func apply(name: String?, bundleIdentifier: String?, version: String?, to info: NSMutableDictionary) throws {
        // Validate all fields before making any change to the working Info.plist.
        let newName = try validated(name, field: .name, original: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String)
        let newBundle = try validated(bundleIdentifier, field: .bundleIdentifier, original: info["CFBundleIdentifier"] as? String)
        let newVersion = try validated(version, field: .version, original: info["CFBundleShortVersionString"] as? String)
        if let newName {
            info["CFBundleName"] = newName
            info["CFBundleDisplayName"] = newName
        }
        if let newBundle { info["CFBundleIdentifier"] = newBundle }
        if let newVersion {
            info["CFBundleShortVersionString"] = newVersion
            info["CFBundleVersion"] = newVersion
        }
    }
}
