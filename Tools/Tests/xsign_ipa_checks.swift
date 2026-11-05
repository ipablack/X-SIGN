extension CatalogLoadingTests {
    static func checkMachOHeaders() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func word(_ value: UInt32, little: Bool = true) -> Data {
            Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ((little ? $0 : 3 - $0) * 8)) })
        }
        func thin(_ cryptid: UInt32, wide: Bool = true, little: Bool = true) -> Data {
            var result = Data()
            for value in [UInt32](arrayLiteral: wide ? 0xfeedfacf : 0xfeedface, 0x0100000c, 0, 2, 1, wide ? 24 : 20, 0) {
                result.append(word(value, little: little))
            }
            if wide { result.append(word(0, little: little)) }
            for value in [UInt32](arrayLiteral: wide ? 0x2c : 0x21, wide ? 24 : 20, 0, 0, cryptid) {
                result.append(word(value, little: little))
            }
            if wide { result.append(word(0, little: little)) }
            return result
        }
        let executable = directory.appendingPathComponent("Executable")
        for wide in [true, false] {
            for little in [true, false] {
                for cryptid in [UInt32(0), 1] {
                    try thin(cryptid, wide: wide, little: little).write(to: executable)
                    let result = try XSignMachOEncryption.isEncrypted(executable: executable)
                    try require(result == (cryptid != 0))
                }
            }
        }
        let first = thin(0), second = thin(1)
        var fat = word(0xcafebabe, little: false) + word(2, little: false)
        let headers: [[UInt32]] = [[0x0100000c, 0, 48, UInt32(first.count), 0], [0x0100000c, 0, UInt32(48 + first.count), UInt32(second.count), 0]]
        for values in headers {
            for value in values { fat.append(word(value, little: false)) }
        }
        fat.append(first); fat.append(second)
        try fat.write(to: executable)
        let fatEncrypted = try XSignMachOEncryption.isEncrypted(executable: executable)
        try require(fatEncrypted)
        for invalid in [Data(), Data("not a Mach-O".utf8), Data(thin(0).prefix(40)), Data(fat.prefix(45))] {
            try invalid.write(to: executable)
            do { _ = try XSignMachOEncryption.isEncrypted(executable: executable); throw CheckFailure("Invalid Mach-O accepted") }
            catch is XSignMachOEncryption.InspectionError {}
        }
        let payload = directory.appendingPathComponent("Payload")
        let app = payload.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable":"Fixture"], format: .xml, options: 0)
        try info.write(to: app.appendingPathComponent("Info.plist"))
        try thin(0).write(to: app.appendingPathComponent("Fixture"))
        try XSignMachOEncryption.verifyPayload(at: payload)
        let framework = app.appendingPathComponent("Frameworks/Fixture.framework")
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        try info.write(to: framework.appendingPathComponent("Info.plist"))
        try thin(1).write(to: framework.appendingPathComponent("Fixture"))
        do { try XSignMachOEncryption.verifyPayload(at: payload); throw CheckFailure("Encrypted embedded framework accepted") }
        catch XSignMachOEncryption.InspectionError.encryptedExecutable {}
        print("PASS: 32/64-bit and both-endian Mach-O cryptid checks, fat slices, malformed headers and encrypted embedded framework rejection")
    }

    static func checkIPAProvider(_ base: URL) async throws {
        let endpoint = base.appendingPathComponent("ipa/success")
        let query = try XSignIPAProvider.requestURL(endpoint: endpoint, bundleID: "org.fixture.app", name: "تطبيق + Test", appStoreID: "123")
        try require(query.absoluteString.contains("%2B"))
        let provider = XSignIPAProvider(endpoint: endpoint)
        let file = try await provider.resolve(bundleID: "org.fixture.app", name: "تطبيق + Test", appStoreID: "123")
        try require(file.absoluteString == "https://example.org/app.ipa?signature=a%2Bb")
        do {
            let forbidden = XSignIPAProvider(endpoint: base.appendingPathComponent("ipa/forbidden"))
            _ = try await forbidden.resolve(bundleID: "org.fixture.app", name: "تطبيق + Test", appStoreID: "123")
            throw CheckFailure("403 was accepted")
        } catch XSignIPAProviderError.permissionDenied {}
        for path in ["missing", "insecure"] {
            let client = XSignIPAProvider(endpoint: base.appendingPathComponent("ipa/" + path))
            do { _ = try await client.resolve(bundleID: "org.fixture.app", name: "تطبيق + Test", appStoreID: "123"); throw CheckFailure("Unavailable/insecure IPA accepted") }
            catch is XSignIPAProviderError {}
        }
        do { _ = try XSignIPAProvider.decode(Data("<html>not JSON</html>".utf8), status: 200); throw CheckFailure("Invalid JSON accepted") }
        catch XSignIPAProviderError.invalidResponse {}
        print("PASS: actual provider client encodes Arabic/plus safely, sends no credentials, preserves signed result URLs and reports 403/unavailable/malformed responses")
    }
}
