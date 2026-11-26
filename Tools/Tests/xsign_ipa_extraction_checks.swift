import Foundation
import ZIPFoundation

struct IPAExtractionChecks {
    static func run() throws {
        guard let fixtures = ProcessInfo.processInfo.environment["XSIGN_IPA_FIXTURES"] else { fatalError("Missing ZIP fixtures") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try checkDebianArchive(in: root)
        let sentinel = root.appendingPathComponent("outside.txt")
        try Data("preserve".utf8).write(to: sentinel)
        let source = URL(fileURLWithPath: fixtures)
        let unsigned = try XSignIPAExtractor.readUpdateMetadata(source.appendingPathComponent("valid.ipa"))
        precondition(unsigned.info == Data("fixture".utf8) && unsigned.provision == nil)
        let ready = try XSignIPAExtractor.readUpdateMetadata(source.appendingPathComponent("signed-update.ipa"))
        precondition(ready.info == unsigned.info && ready.provision == Data("provision".utf8))
        for name in ["update-multiple-apps", "update-metadata-collision", "traversal", "symlink"] {
            do {
                _ = try XSignIPAExtractor.readUpdateMetadata(source.appendingPathComponent(name + ".ipa"))
                fatalError("Unsafe update archive accepted: \(name)")
            } catch is XSignIPAExtractor.InvalidArchive {}
        }
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
        print("PASS: valid IPA, path validation, CRC, expansion limits and safe DEB parsing")
    }

    private static func checkDebianArchive(in root: URL) throws {
        func member(_ name: String, _ value: String) -> Data {
            let field = name.padding(toLength: 16, withPad: " ", startingAt: 0)
            let size = String(value.utf8.count).padding(toLength: 10, withPad: " ", startingAt: 0)
            return Data((field + String(repeating: " ", count: 32) + size + "`\n" + value
                + (value.utf8.count.isMultiple(of: 2) ? "" : "\n")).utf8)
        }
        let package = root.appendingPathComponent("example.deb")
        var bytes = Data("!<arch>\n".utf8)
        bytes.append(member("debian-binary/", "2.0\n"))
        bytes.append(member("data.tar/", "abc"))
        bytes.append(member("control.tar/", "meta"))
        try bytes.write(to: package)
        let payload = try AR(with: package).member(named: ["data.tar"])
        precondition(payload.name == "data.tar" && payload.data == Data("abc".utf8))
        do {
            _ = try AR(with: package).member(named: ["data.tar.gz"])
            fatalError("Missing DEB payload was accepted")
        } catch ARError.missingPayload {}
        try Data().write(to: package)
        do {
            _ = try AR(with: package).member(named: ["data.tar"])
            fatalError("Empty DEB was accepted")
        } catch ARError.invalidArchive {}
    }
}
