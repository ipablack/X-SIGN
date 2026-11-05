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
		let configuration = URLSessionConfiguration.default
		_session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
	}
	
	func startDownload(
		from url: URL,
		id: String = UUID().uuidString,
		sourceProvenance: SourceAppProvenance? = nil,
        requireUnencryptedBinary: Bool = false
	) -> Download {
		let requestHasSourceProvenance = sourceProvenance != nil
		if let existingDownload = downloads.first(where: {
			$0.url == url && ($0.sourceProvenance != nil) == requestHasSourceProvenance && $0.requireUnencryptedBinary == requireUnencryptedBinary
		}) {
            // The original request may be checking policy, downloading or importing.
            // A repeated tap must not create a second transfer for the same file.
            return existingDownload
		}
		
		let download = Download(id: id, url: url, sourceProvenance: sourceProvenance, requireUnencryptedBinary: requireUnencryptedBinary)
		
		let task = _session.downloadTask(with: url)
		attach(task, to: download)
        Task { @MainActor in
            if let reason = await XSignRemoteManager.shared.prepareProtectedOperation() {
                self.cancelDownload(download)
                UIAlertController.showAlertWithOk(title: "تنبيه", message: reason)
            } else if self.downloads.contains(where: { $0.id == download.id }) {
                task.resume()
            }
        }
		
		downloads.append(download)
		
		#if !targetEnvironment(macCatalyst)
		if #available(iOS 26.0, *) {
			BackgroundTaskManager.shared.startTask(for: id, filename: url.lastPathComponent)
		} else {
			_updateBackgroundAudioState()
		}
		#endif
		
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
        if download.task?.state == .running { return }
		if let resumeData = download.resumeData {
			let task = _session.downloadTask(withResumeData: resumeData)
			attach(task, to: download)
            download.resumeData = nil
            Task { @MainActor in
                if let reason = await XSignRemoteManager.shared.prepareProtectedOperation() {
                    self.cancelDownload(download)
                    UIAlertController.showAlertWithOk(title: "تنبيه", message: reason)
                } else if self.downloads.contains(where: { $0.id == download.id }) { task.resume() }
            }
			
			#if !targetEnvironment(macCatalyst)
			_updateBackgroundAudioState()
			#endif
		} else if let url = download.task?.originalRequest?.url {
			let task = _session.downloadTask(with: url)
			attach(task, to: download)
            Task { @MainActor in
                if let reason = await XSignRemoteManager.shared.prepareProtectedOperation() {
                    self.cancelDownload(download)
                    UIAlertController.showAlertWithOk(title: "تنبيه", message: reason)
                } else if self.downloads.contains(where: { $0.id == download.id }) { task.resume() }
            }
			
			#if !targetEnvironment(macCatalyst)
			_updateBackgroundAudioState()
			#endif
		}
	}
	
	func cancelDownload(_ download: Download) {
		download.task?.cancel()
        if let task = download.task { forget(task) }
		
		if let index = downloads.firstIndex(where: { $0.id == download.id }) {
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
	
	func handlePachageFile(url: URL, dl: Download) throws {
		FR.handlePackageFile(url, download: dl, consumeTemporaryFile: true) { err in
            try? FileManager.default.removeItem(at: url)
			if err != nil {
				let generator = UINotificationFeedbackGenerator()
				generator.notificationOccurred(.error)
                UIAlertController.showAlertWithOk(title: "تعذّر استيراد IPA", message: err?.localizedDescription ?? "ملف التطبيق غير صالح.")
			}
			
			DispatchQueue.main.async {
				if let index = DownloadManager.shared.getDownloadIndex(by: dl.id) {
					DownloadManager.shared.downloads.remove(at: index)
					
					#if !targetEnvironment(macCatalyst)
					if #available(iOS 26.0, *) {
						BackgroundTaskManager.shared.updateProgress(for: dl.id, progress: 1.0)
                        BackgroundTaskManager.shared.stopTask(for: dl.id, success: err == nil)
					}
					
					self._updateBackgroundAudioState()
					#endif
				}
			}
		}
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
			try FileManager.default.createDirectoryIfNeeded(at: customTempDir)
			
			// Use the server-suggested filename if available, otherwise fallback
			let suggestedFileName = downloadTask.response?.suggestedFilename ?? download.fileName
            let suggestedExtension = URL(fileURLWithPath: suggestedFileName).pathExtension.lowercased()
            let ext = ["ipa", "tipa", "zip"].contains(suggestedExtension) ? suggestedExtension : "ipa"
            // Resolver URLs may end in .php; independent downloads must never overwrite each other.
			let destinationURL = customTempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
			
			try FileManager.default.removeFileIfNeeded(at: destinationURL)
			try FileManager.default.moveItem(at: location, to: destinationURL)
			
			try handlePachageFile(url: destinationURL, dl: download)
		} catch {
            DispatchQueue.main.async {
                self.cancelDownload(download)
                UIAlertController.showAlertWithOk(title: "تعذّر تنزيل IPA", message: error.localizedDescription)
            }
		}
	}
	
	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
		guard let download = getDownloadTask(by: downloadTask) else { return }
        let tick = totalBytesExpectedToWrite > 0
            ? Int(min(100, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100)))
            : Int(totalBytesWritten / 262_144)
        guard download.transferProgressGate.shouldPublish(tick) else { return }
		
		DispatchQueue.main.async {
            guard self.downloads.contains(where: { $0.id == download.id }) else { return }
			download.progress = totalBytesExpectedToWrite > 0
			? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
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
			let _ = error,
			let downloadTask = task as? URLSessionDownloadTask,
			let download = getDownloadTask(by: downloadTask)
		else {
			return
		}
        forget(downloadTask)
		DispatchQueue.main.async {
            self.cancelDownload(download)
            if let error, (error as? URLError)?.code != .cancelled {
                UIAlertController.showAlertWithOk(title: "تعذّر تنزيل IPA", message: error.localizedDescription)
            }
		}
	}
}
