import Foundation

@main struct PrivateStorageChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let documents = root.appendingPathComponent("Documents")
        let library = root.appendingPathComponent("Library")
        let work = root.appendingPathComponent("Work")
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        for name in ["Signed", "Unsigned", "Certificates", "Archives"] {
            let directory = documents.appendingPathComponent(name)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("preserve-\(name)".utf8).write(to: directory.appendingPathComponent("fixture"))
        }
        try Data("private-pairing-fixture".utf8).write(to: documents.appendingPathComponent("pairingFile.plist"))
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("stale-install-package".utf8).write(to: work.appendingPathComponent("stale.ipa"))
        try XSignPrivateFiles.migrateLegacyDirectories(documents: documents, privateRoot: library, work: work)
        for name in ["Signed", "Unsigned", "Certificates", "Archives"] {
            let data = try Data(contentsOf: library.appendingPathComponent(name).appendingPathComponent("fixture"))
            precondition(data == Data("preserve-\(name)".utf8))
            precondition(!fm.fileExists(atPath: documents.appendingPathComponent(name).path))
        }
        precondition(!fm.fileExists(atPath: work.appendingPathComponent("stale.ipa").path))
        let pairing = try Data(contentsOf: library.appendingPathComponent("pairingFile.plist"))
        precondition(pairing == Data("private-pairing-fixture".utf8))
        precondition(!fm.fileExists(atPath: documents.appendingPathComponent("pairingFile.plist").path))
        try XSignPrivateFiles.migrateLegacyDirectories(documents: documents, privateRoot: library, work: work)
        let oldPairing=documents.appendingPathComponent("pairingFile.plist")
        let differentPairing=Data("different-unused-pairing".utf8)
        try differentPairing.write(to:oldPairing)
        try XSignPrivateFiles.migrateLegacyDirectories(documents:documents,privateRoot:library,work:work)
        let unchangedPairing=try Data(contentsOf:library.appendingPathComponent("pairingFile.plist"))
        precondition(unchangedPairing==pairing && !fm.fileExists(atPath:oldPairing.path))
        let backups=try fm.contentsOfDirectory(at:library.appendingPathComponent("LegacyInstallation"),includingPropertiesForKeys:nil)
        precondition(backups.count==1)
        let preservedPairing=try Data(contentsOf:backups[0])
        precondition(preservedPairing==differentPairing)
        let sentinel=root.appendingPathComponent("keep-private.plist")
        try Data("keep-safe".utf8).write(to:sentinel)
        try fm.createSymbolicLink(at:oldPairing,withDestinationURL:sentinel)
        try XSignPrivateFiles.migrateLegacyDirectories(documents:documents,privateRoot:library,work:work)
        let retainedSentinel=try Data(contentsOf:sentinel)
        precondition(retainedSentinel==Data("keep-safe".utf8))
        let collision = documents.appendingPathComponent("Signed")
        try fm.createDirectory(at: collision, withIntermediateDirectories: true)
        try Data("new-unexpected-copy".utf8).write(to: collision.appendingPathComponent("fixture"))
        do {
            try XSignPrivateFiles.migrateLegacyDirectories(documents: documents, privateRoot: library, work: work)
            fatalError("Migration overwrote a conflicting app")
        } catch { precondition((error as NSError).code == 409) }
        let retainedOld = try Data(contentsOf: collision.appendingPathComponent("fixture"))
        let retainedNew = try Data(contentsOf: library.appendingPathComponent("Signed/fixture"))
        precondition(retainedOld == Data("new-unexpected-copy".utf8) && retainedNew == Data("preserve-Signed".utf8))
        print("PASS: private migration preserves payloads, removes public copies, clears temporary packages and rejects conflicts")
    }
}
