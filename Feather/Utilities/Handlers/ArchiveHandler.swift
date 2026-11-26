import Foundation
import ZIPFoundation

// Creates a private, temporary IPA for the iOS installer. There is no export or share API.
final class ArchiveHandler {
    private let app: AppInfoPresentable
    private let work = XSignPrivateFiles.workDirectory(prefix: "Install")
    private var payload: URL?

    init(app: AppInfoPresentable) {
        self.app = app
    }

    @discardableResult
    func move() async throws -> XSignOTABundleMetadata {
        guard let original = await MainActor.run(body: { Storage.shared.getAppDirectory(for: self.app) }) else {
            throw SigningFileHandlerError.appNotFound
        }
        try XSignIPAExtractor.validateTree(original)
        let payload = work.appendingPathComponent("Payload")
        try XSignPrivateFiles.createDirectory(payload)
        let copied = payload.appendingPathComponent(original.lastPathComponent)
        try XSignPrivateFiles.copyToWork(original, to: copied)
        let metadata = try XSignOTABundleMetadata.read(from: copied)
        self.payload = payload
        return metadata
    }

    func archive() async throws -> URL {
        guard let payload else { throw SigningFileHandlerError.appNotFound }
        let package = work.appendingPathComponent("Install.ipa")
        let compress = UserDefaults.standard.integer(forKey: "Feather.compressionLevel") == 8
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try FileManager.default.zipItem(at: payload, to: package, shouldKeepParent: true, compressionMethod: compress ? .deflate : .none)
            try XSignPrivateFiles.protect(package)
        }.value
        return package
    }

    func clean() { try? FileManager.default.removeItem(at: work) }
}
