//
//  enum.swift
//  Feather
//
//  Created by samara on 3.05.2025.
//

import Foundation
import Combine
import UIKit.UIImpactFeedbackGenerator
import BackgroundTasks

class Download: Identifiable, @unchecked Sendable {
	@Published var progress: Double = 0.0
	@Published var bytesDownloaded: Int64 = 0
	@Published var totalBytes: Int64 = 0
	@Published var unpackageProgress: Double = 0.0
	
	var overallProgress: Double {
		onlyArchiving
		? unpackageProgress
		: (0.3 * unpackageProgress) + (0.7 * progress)
	}
	
	var task: URLSessionDownloadTask?
	var resumeData: Data?
    var protectedTransfer: UUID?
    var importTask: Task<Void, Never>?
	
	let id: String
	let url: URL
	let fileName: String
	let onlyArchiving: Bool
    let requireUnencryptedBinary: Bool
    let transferProgressGate = XSignDownloadProgressGate()
	var sourceProvenance: SourceAppProvenance?
	
	init(
		id: String,
		url: URL,
		onlyArchiving: Bool = false,
		sourceProvenance: SourceAppProvenance? = nil,
        requireUnencryptedBinary: Bool = false
	) {
		self.id = id
		self.url = url
		self.onlyArchiving = onlyArchiving
		self.sourceProvenance = sourceProvenance
        self.requireUnencryptedBinary = requireUnencryptedBinary
		self.fileName = url.lastPathComponent
	}
}

class DownloadManager: NSObject, ObservableObject {
	static let shared = DownloadManager()
	
    @Published var downloads: [Download] = []
    private var completedSourceImports: [String] = []
    private static let sourceImportPrefix = "xsign-source-import:"

    static func sourceImportID(for url: URL) -> String { sourceImportPrefix + url.absoluteString }

    func didCompleteSourceImport(_ id: String) -> Bool { completedSourceImports.contains(id) }
	
	var manualDownloads: [Download] {
		downloads.filter { isManualDownload($0.id) }
	}
	
	private var _session: URLSession!
    private let transferLock = NSLock()
    private var taskDownloads: [Int: Download] = [:]

    private func attach(_ task: URLSessionDownloadTask, to download: Download) {
        download.task = task
        transferLock.lock()
        taskDownloads = taskDownloads.filter { $0.value.id != download.id }
        taskDownloads[task.taskIdentifier] = download
        transferLock.unlock()
    }

    private func forget(_ task: URLSessionTask) {
        transferLock.lock()
        taskDownloads.removeValue(forKey: task.taskIdentifier)
        transferLock.unlock()
    }
	
	#if !targetEnvironment(macCatalyst)
	private func _updateBackgroundAudioState() {
		if #unavailable(iOS 26.0){
			if !downloads.isEmpty {
				BackgroundAudioManager.shared.start()
			} else  {
				BackgroundAudioManager.shared.stop()
			}
		}
	}
	#endif
	
	override init() {
		super.init()
		let configuration = URLSessionConfiguration.ephemeral
		configuration.urlCache = nil
		_session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
	}
	
	func startDownload(
		from url: URL,
		id: String = UUID().uuidString,
		sourceProvenance: SourceAppProvenance? = nil,
        requireUnencryptedBinary: Bool = false
	) -> Download {
        let sourceImport = id.hasPrefix(Self.sourceImportPrefix)
        let requestHasSourceProvenance = sourceProvenance != nil
		if let existingDownload = downloads.first(where: {
            $0.id == id || (!sourceImport && !$0.id.hasPrefix(Self.sourceImportPrefix)
                && $0.url == url && ($0.sourceProvenance != nil) == requestHasSourceProvenance &&
                $0.requireUnencryptedBinary == requireUnencryptedBinary)
		}) {
            // The original request may be checking policy, downloading or importing.
            // A repeated tap must not create a second transfer for the same file.
            return existingDownload
		}
		
		let download = Download(id: id, url: url, sourceProvenance: sourceProvenance, requireUnencryptedBinary: requireUnencryptedBinary)
		
        guard XSignManagedSource.httpsURL(url.absoluteString) != nil else {
            UIAlertController.showAlertWithOk(title: xsignText("تعذّر تنزيل IPA"), message: xsignText("يلزم رابط HTTPS صالح للملف."))
            return download
        }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
		let task = _session.downloadTask(with: request)
		attach(task, to: download)
		
        completedSourceImports.removeAll { $0 == id }
        downloads.append(download)

		#if !targetEnvironment(macCatalyst)
		if #available(iOS 26.0, *) {
			BackgroundTaskManager.shared.startTask(for: id, filename: url.lastPathComponent)
		} else {
			_updateBackgroundAudioState()
		}
		#endif
        prepareAndResume(task, for: download)
		
		return download
	}
	
	func startArchive(
		from url: URL,
		id: String = UUID().uuidString
	) -> Download {
		let download = Download(id: id, url: url, onlyArchiving: true)
		downloads.append(download)
		
		#if !targetEnvironment(macCatalyst)
		_updateBackgroundAudioState()
		#endif
		
		return download
	}
	
	func resumeDownload(_ download: Download) {
        guard downloads.contains(where: { $0 === download }),
              download.importTask == nil, download.task?.state != .running else { return }
        let task: URLSessionDownloadTask
        if let resumeData = download.resumeData {
            task = _session.downloadTask(withResumeData: resumeData)
            download.resumeData = nil
        } else {
            guard XSignManagedSource.httpsURL(download.url.absoluteString) != nil else { return }
            download.resumeData = nil
            let request = URLRequest(url: download.url, cachePolicy: .reloadIgnoringLocalCacheData)
            task = _session.downloadTask(with: request)
        }
        let previousTask = download.task
        attach(task, to: download)
        previousTask?.cancel()
        prepareAndResume(task, for: download)
        #if !targetEnvironment(macCatalyst)
        _updateBackgroundAudioState()
        #endif
	}

    private func prepareAndResume(_ task: URLSessionDownloadTask, for download: Download) {
        Task { @MainActor in
            guard self.ownsTask(task, for: download) else { return }
            let reason = await XSignRemoteManager.shared.prepareProtectedOperation()
            guard self.ownsTask(task, for: download) else { return }
            let security = XSignSecurityEnforcer.shared
            if let reason {
                self.cancelDownload(download)
                security.reportInstallationFailure(reason)
                return
            }
            security.finishProtectedTransfer(download.protectedTransfer)
            download.protectedTransfer = security.startProtectedTransfer { [weak self, weak download] _ in
                if let download { self?.cancelDownload(download) }
            }
            guard download.protectedTransfer != nil else { return }
            task.resume()
        }
    }

    @MainActor
    private func ownsTask(_ task: URLSessionDownloadTask, for download: Download) -> Bool {
        download.task === task && downloads.contains { $0 === download }
    }

    @MainActor
    func applyRemotePolicy() {
        for download in downloads where download.task != nil { cancelDownload(download) }
    }
	
    func cancelDownload(_ download: Download) {
        download.importTask?.cancel()
        download.importTask = nil
        download.task?.cancel()
        if let task = download.task { forget(task) }
        let transfer = download.protectedTransfer
        download.protectedTransfer = nil
        if transfer != nil {
            Task { @MainActor in XSignSecurityEnforcer.shared.finishProtectedTransfer(transfer) }
        }
		
		if let index = downloads.firstIndex(where: { $0 === download }) {
			downloads.remove(at: index)
			
			#if !targetEnvironment(macCatalyst)
			_updateBackgroundAudioState()

			if #available(iOS 26.0, *) {
				BackgroundTaskManager.shared.stopTask(for: download.id, success: false)
			}
			#endif
		}
	}
	
	func isManualDownload(_ string: String) -> Bool {
		return string.contains("FeatherManualDownload")
	}
	
	func getDownload(by id: String) -> Download? {
		return downloads.first(where: { $0.id == id })
	}
	
	func getDownloadIndex(by id: String) -> Int? {
		return downloads.firstIndex(where: { $0.id == id })
	}
	
	func getDownloadTask(by task: URLSessionDownloadTask) -> Download? {
		transferLock.lock()
        defer { transferLock.unlock() }
        return taskDownloads[task.taskIdentifier]
	}
}

extension DownloadManager: URLSessionDownloadDelegate {
	
    @MainActor
	func handlePackageFile(url: URL, dl: Download) {
        dl.importTask = FR.importPackageFile(url, download: dl, consumeTemporaryFile: true) { result in
            dl.importTask = nil
            try? FileManager.default.removeItem(at: url)
            guard let index = self.downloads.firstIndex(where: { $0 === dl }) else {
                if case .success(let uuid) = result { Storage.shared.deleteInterruptedImport(uuid: uuid) }
                return
            }
            XSignSecurityEnforcer.shared.finishProtectedTransfer(dl.protectedTransfer)
            dl.protectedTransfer = nil
            let succeeded: Bool
            switch result {
            case .success:
                succeeded = true
                XSignImportNotices.completed()
                if dl.id.hasPrefix(Self.sourceImportPrefix) {
                    self.completedSourceImports.append(dl.id)
                    if self.completedSourceImports.count > 64 { self.completedSourceImports.removeFirst() }
                }
            case .failure(let error):
                succeeded = false
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                UIAlertController.showAlertWithOk(title: xsignText("تعذّر استيراد IPA"), message: xsignText(error.localizedDescription))
            }
            self.downloads.remove(at: index)
            #if !targetEnvironment(macCatalyst)
            if #available(iOS 26.0, *) {
                if succeeded { BackgroundTaskManager.shared.updateProgress(for: dl.id, progress: 1) }
                BackgroundTaskManager.shared.stopTask(for: dl.id, success: succeeded)
            }
            self._updateBackgroundAudioState()
            #endif
		}
	}
	
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(XSignCatalogueEndpoint.mayRedirect(task, to: request) ? request : nil)
    }

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
		guard let download = getDownloadTask(by: downloadTask) else { return }
        defer { forget(downloadTask) }
		
		let tempDirectory = FileManager.default.temporaryDirectory
		let customTempDir = tempDirectory.appendingPathComponent("FeatherDownloads", isDirectory: true)
		
		do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0 else { throw XSignIPAExtractor.InvalidArchive.corrupt }
            guard Int64(size) <= XSignIPAExtractor.maximumArchiveBytes else {
                throw XSignIPAExtractor.InvalidArchive.tooLarge
            }
			try FileManager.default.createDirectoryIfNeeded(at: customTempDir)
			
			// Use the server-suggested filename if available, otherwise fallback
			let suggestedFileName = downloadTask.response?.suggestedFilename ?? download.fileName
            let suggestedExtension = URL(fileURLWithPath: suggestedFileName).pathExtension.lowercased()
            let ext = ["ipa", "tipa", "zip"].contains(suggestedExtension) ? suggestedExtension : "ipa"
            // Resolver URLs may end in .php; independent downloads must never overwrite each other.
			let destinationURL = customTempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
			
			try FileManager.default.removeFileIfNeeded(at: destinationURL)
			try FileManager.default.moveItem(at: location, to: destinationURL)
			
            Task { @MainActor in
                XSignSecurityEnforcer.shared.evaluateNetworkSecurity()
                guard self.ownsTask(downloadTask, for: download) else {
                    try? FileManager.default.removeItem(at: destinationURL)
                    return
                }
                if let reason = XSignRemoteManager.shared.blockingReason {
                    try? FileManager.default.removeItem(at: destinationURL)
                    self.cancelDownload(download)
                    XSignSecurityEnforcer.shared.reportInstallationFailure(reason)
                    return
                }
                download.progress = 1
                download.bytesDownloaded = Int64(size)
                download.totalBytes = Int64(size)
                self.handlePackageFile(url: destinationURL, dl: download)
            }
		} catch {
            DispatchQueue.main.async {
                XSignSecurityEnforcer.shared.evaluateNetworkSecurity()
                guard self.ownsTask(downloadTask, for: download) else { return }
                self.cancelDownload(download)
                UIAlertController.showAlertWithOk(title: xsignText("تعذّر تنزيل IPA"), message: error.localizedDescription)
            }
		}
	}
	
	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
		guard let download = getDownloadTask(by: downloadTask) else { return }
        let limit = XSignIPAExtractor.maximumArchiveBytes
        if max(totalBytesWritten, totalBytesExpectedToWrite) > limit {
            downloadTask.cancel()
            DispatchQueue.main.async {
                guard self.ownsTask(downloadTask, for: download) else { return }
                self.cancelDownload(download)
                UIAlertController.showAlertWithOk(title: xsignText("تعذّر تنزيل IPA"),
                    message: XSignIPAExtractor.InvalidArchive.tooLarge.localizedDescription)
            }
            return
        }
        let tick = totalBytesExpectedToWrite > 0
            ? Int(min(100, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100)))
            : Int(totalBytesWritten / 262_144)
        guard download.transferProgressGate.shouldPublish(tick) else { return }
		
		DispatchQueue.main.async {
            guard self.ownsTask(downloadTask, for: download) else { return }
			download.progress = totalBytesExpectedToWrite > 0
			? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
            : 0
			download.bytesDownloaded = totalBytesWritten
			download.totalBytes = totalBytesExpectedToWrite
			
			#if !targetEnvironment(macCatalyst)
			if #available(iOS 26.0, *) {
				BackgroundTaskManager.shared.updateProgress(for: download.id, progress: download.overallProgress)
			}
			#endif
		}
	}
	
	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		guard
			let error,
			let downloadTask = task as? URLSessionDownloadTask,
			let download = getDownloadTask(by: downloadTask)
		else {
			return
		}
        forget(downloadTask)
		DispatchQueue.main.async {
            XSignSecurityEnforcer.shared.evaluateNetworkSecurity()
            guard self.ownsTask(downloadTask, for: download) else { return }
            self.cancelDownload(download)
            if (error as? URLError)?.code != .cancelled {
                UIAlertController.showAlertWithOk(title: xsignText("تعذّر تنزيل IPA"), message: error.localizedDescription)
            }
		}
	}
}
