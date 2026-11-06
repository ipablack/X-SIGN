import Foundation

// No signing material or install package lives in the document-sharing directory.
enum XSignPrivateFiles {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XSignPrivate", isDirectory: true)
    }
    static var workRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XSignWork", isDirectory: true)
    }
    static func directory(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }
    static func workDirectory(prefix: String) -> URL { workRoot.appendingPathComponent(prefix + "_" + UUID().uuidString) }

    static func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try protect(url)
    }
    static func protect(_ url: URL) throws {
        var value = url
        var flags = URLResourceValues()
        flags.isExcludedFromBackup = true
        try value.setResourceValues(flags)
        #if os(iOS) || targetEnvironment(macCatalyst)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }

    static func migrateLegacyDirectories(
        documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
        privateRoot: URL = root, work: URL = workRoot
    ) throws {
        let fm = FileManager.default
        try createDirectory(privateRoot)
        try createDirectory(work)
        for name in ["Certificates", "Signed", "Unsigned", "Archives"] {
            let old = documents.appendingPathComponent(name)
            let destination = privateRoot.appendingPathComponent(name)
            if fm.fileExists(atPath: old.path) {
                guard try old.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    throw CocoaError(.fileReadNoPermission)
                }
                if fm.fileExists(atPath: destination.path) {
                    // The launch delegate may have created an empty directory before migration.
                    let oldItems = try fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)
                    for item in oldItems {
                        let target = destination.appendingPathComponent(item.lastPathComponent)
                        guard !fm.fileExists(atPath: target.path) else {
                            throw NSError(domain: "XSign.Storage", code: 409, userInfo: [NSLocalizedDescriptionKey:
                                "توجد نسختان من ملفات التوقيع. احتُفظ بهما دون استبدال؛ يلزم مراجعة البيانات قبل المتابعة."])
                        }
                        try fm.moveItem(at: item, to: target)
                    }
                    try fm.removeItem(at: old)
                } else { try fm.moveItem(at: old, to: destination) }
            }
            try createDirectory(destination)
        }
        // Pairing is not used by the current installer. A legacy backup conflict
        // must not block loading the store or native signing.
        migrateUnusedPairing(documents:documents,privateRoot:privateRoot)
        // Crash leftovers contain install packages; no active jobs exist during app startup.
        for item in try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil) { try fm.removeItem(at: item) }
        let certificates = privateRoot.appendingPathComponent("Certificates")
        if let files = fm.enumerator(at: certificates, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            for case let file as URL in files {
                let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
                try fm.setAttributes([.posixPermissions: values.isDirectory == true ? 0o700 : 0o600], ofItemAtPath: file.path)
                try protect(file)
            }
        }
    }

    private static func migrateUnusedPairing(documents:URL,privateRoot:URL) {
        let fm=FileManager.default
        let old=documents.appendingPathComponent("pairingFile.plist")
        do {
            guard fm.fileExists(atPath:old.path) else { return }
            let values=try old.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard values.isRegularFile==true,values.isSymbolicLink != true,
                  let size=values.fileSize,size<=8_388_608 else { return }
            let destination=privateRoot.appendingPathComponent("pairingFile.plist")
            if fm.fileExists(atPath:destination.path) {
                let saved=try destination.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
                if saved.isRegularFile==true,saved.isSymbolicLink != true,saved.fileSize==size,
                   try Data(contentsOf:old)==Data(contentsOf:destination) {
                    try protect(destination)
                    try fm.removeItem(at:old)
                } else {
                    let backups=privateRoot.appendingPathComponent("LegacyInstallation",isDirectory:true)
                    try createDirectory(backups)
                    let backup=backups.appendingPathComponent("pairing_"+UUID().uuidString+".plist")
                    try fm.moveItem(at:old,to:backup)
                    try protect(backup)
                }
            } else {
                try fm.moveItem(at:old,to:destination)
                try protect(destination)
            }
        } catch {
            // Retain unused legacy data on any failure; do not require pairing.
        }
    }
}
