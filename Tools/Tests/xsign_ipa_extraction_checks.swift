import Foundation
import ZIPFoundation

struct IPAExtractionChecks {
    static func run() throws {
        guard let fixtures = ProcessInfo.processInfo.environment["XSIGN_IPA_FIXTURES"] else { fatalError("Missing ZIP fixtures") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("outside.txt")
        try Data("preserve".utf8).write(to: sentinel)
        let source = URL(fileURLWithPath: fixtures)
        let good = root.appendingPathComponent("Good")
        try XSignIPAExtractor.extract(source.appendingPathComponent("valid.ipa"), to: good)
        precondition(FileManager.default.fileExists(atPath: good.appendingPathComponent("Payload/Test.app/Test").path))
        let internalPackage = root.appendingPathComponent("InternalInstall.ipa")
        try FileManager.default.zipItem(at: good.appendingPathComponent("Payload"), to: internalPackage,
                                       shouldKeepParent: true, compressionMethod: .none)
        let roundTrip = root.appendingPathComponent("RoundTrip")
        try XSignIPAExtractor.extract(internalPackage, to: roundTrip)
        let repacked = try Data(contentsOf: roundTrip.appendingPathComponent("Payload/Test.app/Test"))
        precondition(repacked == Data("fixture-executable".utf8))
        for name in ["traversal", "absolute", "backslash", "symlink", "case-collision", "file-directory", "crc-corrupt"] {
            let destination = root.appendingPathComponent(name)
            do { try XSignIPAExtractor.extract(source.appendingPathComponent(name + ".ipa"), to: destination); fatalError("Unsafe archive accepted: \(name)") }
            catch { precondition(!FileManager.default.fileExists(atPath: destination.path)) }
            let retained = try Data(contentsOf: sentinel)
            precondition(retained == Data("preserve".utf8))
        }
        var limits = XSignIPAExtractor.Limits()
        limits.expandedBytes = 4
        do { try XSignIPAExtractor.extract(source.appendingPathComponent("valid.ipa"), to: root.appendingPathComponent("Limited"), limits: limits); fatalError("Expansion budget ignored") }
        catch XSignIPAExtractor.InvalidArchive.tooLarge {}
        let link = good.appendingPathComponent("Payload/Test.app/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        do { try XSignIPAExtractor.validateTree(good); fatalError("Legacy symlink was accepted by native signing preflight") }
        catch XSignIPAExtractor.InvalidArchive.unsupportedLink {}
        print("PASS: valid IPA, path traversal, absolute paths, symlinks, case collisions, CRC corruption and expansion limits")
    }
}
