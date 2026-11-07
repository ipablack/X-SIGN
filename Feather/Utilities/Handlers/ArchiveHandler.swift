import Foundation
import SwiftUI
import ZIPFoundation
import IDeviceSwift

// Creates a private, temporary IPA for the iOS installer. There is no export or share API.
final class ArchiveHandler: NSObject {
    @ObservedObject var viewModel: InstallerStatusViewModel
    private let fileManager = FileManager.default
    private let app: AppInfoPresentable
    private let work = XSignPrivateFiles.workDirectory(prefix: "Install")
    private var payload: URL?
    private(set) var installationMetadata: XSignOTABundleMetadata?

    init(app: AppInfoPresentable, viewModel: InstallerStatusViewModel) {
        self.app = app
        self.viewModel = viewModel
        super.init()
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
        try fileManager.copyItem(at: original, to: copied)
        let metadata = try XSignOTABundleMetadata.read(from: copied)
        installationMetadata = metadata
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
        await MainActor.run { self.viewModel.packageProgress = 1 }
        return package
    }

    func clean() { try? fileManager.removeItem(at: work) }
}
