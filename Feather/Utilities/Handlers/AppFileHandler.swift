//
//  IPAHandler.swift
//  Feather
//
//  Created by samara on 11.04.2025.
//

import Foundation

import SwiftUI

final class AppFileHandler: NSObject, @unchecked Sendable {
	private let _fileManager = FileManager.default
	private let _uuid = UUID().uuidString
    var resultUUID: String { _uuid }
	private let _uniqueWorkDir: URL
	var uniqueWorkDirPayload: URL?

	private var _ipa: URL
	private let _install: Bool
	private let _download: Download?
	private let _sourceProvenance: SourceAppProvenance?
    private let _consumeTemporaryFile: Bool
	
	init(
		file ipa: URL,
		install: Bool = false,
		download: Download? = nil,
		sourceProvenance: SourceAppProvenance? = nil,
        consumeTemporaryFile: Bool = false
	) {
		self._ipa = ipa
		self._install = install
		self._download = download
		self._sourceProvenance = sourceProvenance ?? download?.sourceProvenance
        self._consumeTemporaryFile = consumeTemporaryFile
		self._uniqueWorkDir = XSignPrivateFiles.workDirectory(prefix: "Import")
		
		super.init()
	}
	
	func copy() async throws {
        let input = try _ipa.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard _ipa.isFileURL, input.isRegularFile == true, input.isSymbolicLink != true,
              let size = input.fileSize, size > 0, Int64(size) <= XSignIPAExtractor.maximumArchiveBytes else {
            throw XSignIPAExtractor.InvalidArchive.tooLarge
        }
		try XSignPrivateFiles.createDirectory(_uniqueWorkDir)
		
		let destinationURL = _uniqueWorkDir.appendingPathComponent(_ipa.lastPathComponent)

		try _fileManager.removeFileIfNeeded(at: destinationURL)
		
        if _consumeTemporaryFile {
            let temporary = _fileManager.temporaryDirectory.resolvingSymlinksInPath().path + "/"
            guard _ipa.resolvingSymlinksInPath().path.hasPrefix(temporary) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            // The caller owns this temporary download. Rename instead of copying the whole IPA.
            try _fileManager.moveItem(at: _ipa, to: destinationURL)
        } else {
            try XSignPrivateFiles.copyToWork(_ipa, to: destinationURL)
        }
		_ipa = destinationURL
	}
	
    // Called by the detached import task so extraction sees that task's cancellation.
    func extract() throws {
        let download = _download
        let progressGate = XSignDownloadProgressGate()
        let extracted = _uniqueWorkDir.appendingPathComponent("Extracted")
        try XSignIPAExtractor.extract(_ipa, to: extracted, engine: .selected) { progress in
            guard let download, progress.isFinite,
                  progressGate.shouldPublish(Int(max(0, min(1, progress)) * 100)) else { return }
            DispatchQueue.main.async {
                download.unpackageProgress = progress
                #if !targetEnvironment(macCatalyst)
                if #available(iOS 26.0, *) {
                    BackgroundTaskManager.shared.updateProgress(for: download.id, progress: download.overallProgress)
                }
                #endif
            }
        }
        let payload = extracted.appendingPathComponent("Payload", isDirectory: true)
        guard let app = _fileManager.getPath(in: payload, for: "app") else {
            throw XSignIPAExtractor.InvalidArchive.missingPayload
        }
        let infoURL = app.appendingPathComponent("Info.plist")
        guard let size = try? infoURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= 1_048_576,
              let info = try? XSignAppMetadata.readInfo(at: infoURL),
              let identifier = info["CFBundleIdentifier"] as? String, !identifier.trimmingCharacters(in: .whitespaces).isEmpty,
              let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty,
              executable != ".", executable != "..", !executable.contains("/"), !executable.contains("\\"),
              let binary = try? app.appendingPathComponent(executable).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              binary.isRegularFile == true, (binary.fileSize ?? 0) > 0 else {
            throw XSignIPAExtractor.InvalidArchive.invalidApp
        }
        if download?.requireUnencryptedBinary == true {
            try XSignMachOEncryption.verifyPayload(at: payload)
        }
        uniqueWorkDirPayload = payload
    }

	func move() async throws {
		guard let payloadURL = uniqueWorkDirPayload else {
			throw ImportedFileHandlerError.payloadNotFound
		}
		
		let destinationURL = try await _directory()
		
		guard _fileManager.fileExists(atPath: payloadURL.path) else {
			throw ImportedFileHandlerError.payloadNotFound
		}
		
		try _fileManager.moveItem(at: payloadURL, to: destinationURL)
		
		try? _fileManager.removeItem(at: _uniqueWorkDir)
	}
	
	@MainActor
	func addToDatabase() async throws {
		let app = try await _directory()
		
		guard let appUrl = _fileManager.getPath(in: app, for: "app") else {
			throw ImportedFileHandlerError.payloadNotFound
		}
		
        guard let bundle = Bundle(url: appUrl), let identifier = bundle.bundleIdentifier else {
            throw XSignIPAExtractor.InvalidArchive.invalidApp
        }
		
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Storage.shared.addImported(
                uuid: _uuid,
                source: _sourceProvenance?.sourceRepositoryURL,
                appName: bundle.name,
                appIdentifier: identifier,
                appVersion: bundle.version,
                appIcon: bundle.iconFileName
            ) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }

		if let sourceProvenance = _sourceProvenance {
			Storage.shared.addSourceMetadata(
				for: _uuid,
				kind: .imported,
				provenance: sourceProvenance
			)
		}
	}
	
	private func _directory() async throws -> URL {
		// Documents/Feather/Unsigned/\(UUID)
		_fileManager.unsigned(_uuid)
	}
	
	func clean() async throws {
		try _fileManager.removeFileIfNeeded(at: _uniqueWorkDir)
	}
}

private enum ImportedFileHandlerError: Error {
	case payloadNotFound
}
