//
//  BackgroundTaskManager.swift
//  Feather
//
//  Created by Nagata Asami on 4/1/26.
//

#if !targetEnvironment(macCatalyst)

import Foundation
import BackgroundTasks
import CryptoKit

@available(iOS 26.0, *)
class BackgroundTaskManager: ObservableObject {
	static let shared = BackgroundTaskManager()
	
	private let baseId = "\(Bundle.main.bundleIdentifier!).userTask"
	
	private var activeTasks: [String: BGContinuedProcessingTask] = [:]
	private var registeredTasks: Set<String> = []
	
	func startTask(for downloadId: String, filename: String) {
		let taskIdentifier = "\(baseId).\(downloadId.md5)"
		
		if !registeredTasks.contains(taskIdentifier) {
			BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
				guard let task = task as? BGContinuedProcessingTask else { return }
                Task { @MainActor in
                    let manager = DownloadManager.shared
                    guard let download = manager.getDownload(by: downloadId) else {
                        task.setTaskCompleted(success: false)
                        return
                    }
                    self.activeTasks[task.identifier] = task
                    task.expirationHandler = { [weak self, weak task, weak download] in
                        Task { @MainActor in
                            guard let self, let task, self.activeTasks[task.identifier] === task else { return }
                            let security = XSignSecurityEnforcer.shared
                            security.evaluateNetworkSecurity()
                            guard self.activeTasks[task.identifier] === task else { return }
                            if let download, manager.getDownload(by: downloadId) === download {
                                manager.cancelDownload(download)
                                security.reportInstallationFailure(XSignSecurityEnforcer.backgroundFailure)
                            } else {
                                self.stopTask(for: downloadId, success: false)
                            }
                        }
                    }
                }
			}
			self.registeredTasks.insert(taskIdentifier)
		}
		
		let request = BGContinuedProcessingTaskRequest(identifier: taskIdentifier, title: filename, subtitle: .localized("Downloading"))
		request.strategy = .queue
		do {
			try BGTaskScheduler.shared.submit(request)
		} catch {
			print(error)
		}
	}
	
	func updateProgress(for downloadId: String, progress: Double) {
		let taskIdentifier = "\(baseId).\(downloadId.md5)"
		
		guard let task = activeTasks[taskIdentifier], progress.isFinite else { return }
        let percent = Int(min(1, max(0, progress)) * 100)
		task.progress.totalUnitCount = 100
		task.progress.completedUnitCount = Int64(percent)
		
		task.updateTitle(task.title, subtitle: "\(percent)%")
	}
	
	func stopTask(for downloadId: String, success: Bool) {
		let taskIdentifier = "\(baseId).\(downloadId.md5)"
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
		guard let task = activeTasks[taskIdentifier] else { return }
		
		task.setTaskCompleted(success: success)
		activeTasks.removeValue(forKey: taskIdentifier)
	}
}

extension String {
	var md5: String {
		Insecure.MD5.hash(data: Data(self.utf8)).map { String(format: "%02hhx", $0) }.joined()
	}
}

#endif
