//
//  ArchiveHandler.swift
//  Feather
//
//  Created by samara on 22.04.2025.
//

import Foundation
import UIKit.UIApplication
import Zip
import SwiftUI
import IDeviceSwift

final class ArchiveHandler: NSObject {
	@ObservedObject var viewModel: InstallerStatusViewModel
	
	private let _fileManager = FileManager.default
	private let _uuid = UUID().uuidString
	private var _payloadUrl: URL?
	
	private var _app: AppInfoPresentable
	private let _uniqueWorkDir: URL
	
	init(app: AppInfoPresentable, viewModel: InstallerStatusViewModel) {
		self.viewModel = viewModel
		self._app = app
		self._uniqueWorkDir = _fileManager.temporaryDirectory
			.appendingPathComponent("FeatherInstall_\(_uuid)", isDirectory: true)
		
		super.init()
	}
	
	func move() async throws {
		let storedURL = await MainActor.run { Storage.shared.getAppDirectory(for: self._app) }
		guard let appUrl = storedURL else {
			throw SigningFileHandlerError.appNotFound
		}
		
		let payloadUrl = _uniqueWorkDir.appendingPathComponent("Payload")
		let movedAppURL = payloadUrl.appendingPathComponent(appUrl.lastPathComponent)

		try _fileManager.createDirectoryIfNeeded(at: payloadUrl)
		
		try _fileManager.copyItem(at: appUrl, to: movedAppURL)
		_payloadUrl = payloadUrl
	}
	
	func archive(forLocalInstallation: Bool = false) async throws -> URL {
		return try await Task.detached(priority: .userInitiated) { [self] in
			guard let payloadUrl = await self._payloadUrl else {
				throw SigningFileHandlerError.appNotFound
			}
			
			let zipUrl = self._uniqueWorkDir.appendingPathComponent("Archive.zip")
			let ipaUrl = self._uniqueWorkDir.appendingPathComponent("Archive.ipa")
			
            let progressGate = XSignDownloadProgressGate()
			try await Zip.zipFiles(
				paths: [payloadUrl],
				zipFilePath: zipUrl,
				password: nil,
				compression: forLocalInstallation ? .NoCompression : ZipCompression.allCases[min(ZipCompression.allCases.count - 1, max(0, ArchiveHandler.getCompressionLevel()))],
				progress: { progress in
                    guard progress.isFinite, progressGate.shouldPublish(Int(progress * 100)) else { return }
					Task { @MainActor in
						self.viewModel.packageProgress = progress
					}
				})
			
			try FileManager.default.moveItem(at: zipUrl, to: ipaUrl)
			return ipaUrl
		}.value
	}
	
	func moveToArchive(_ package: URL, shouldOpen: Bool = false) async throws -> URL? {
		let values = await MainActor.run { (self._app.name, self._app.version) }
        let appendingString = XSignAppMetadata.archiveFileName(name: values.0, version: values.1, suffix: "\(Int(Date().timeIntervalSince1970))_\(_uuid.prefix(8))")
		let dest = _fileManager.archives.appendingPathComponent(appendingString)
		
		try _fileManager.moveItem(
			at: package,
			to: dest
		)
		
		if shouldOpen, let sharedURL = FileManager.default.archives.toSharedDocumentsURL() {
			await MainActor.run {
				UIApplication.open(sharedURL)
			}
		}
		
		return dest
	}
	
	static func getCompressionLevel() -> Int {
		UserDefaults.standard.integer(forKey: "Feather.compressionLevel")
	}
}
