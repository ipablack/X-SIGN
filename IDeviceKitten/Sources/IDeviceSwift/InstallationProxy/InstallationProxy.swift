//
//  ConduitInstaller.swift
//  Feather
//
//  Created by samara on 23.04.2025.
//

import Foundation
import SwiftUI
import IDevice
import UIKit.UIApplication

public class InstallationProxy: Identifiable, ObservableObject {
	private let _heartbeat = HeartbeatManager.shared
	private let _uuid = UUID().uuidString
	
	typealias AfcClientHandle = OpaquePointer
	typealias AfcFileHandle = OpaquePointer
	typealias InstallationProxyClientHandle = OpaquePointer
	
	@ObservedObject
	public var viewModel: InstallerStatusViewModel
	
	public init(viewModel: InstallerStatusViewModel) {
		self.viewModel = viewModel
	}
	
	public func install(at url: URL, suspend: Bool = false) async throws {
		var afcClient: AfcClientHandle?
		var fileHandle: AfcFileHandle?
		var installproxy: InstallationProxyClientHandle?
        var remotePackage: String?

		
		let worker = Task.detached(priority: .utility) {
			guard FileManager.default.fileExists(atPath: HeartbeatManager.pairingFile()) else {
				throw IDeviceSwiftError(message: "Missing Pairing")
			}
			
			let isRsd = await self._heartbeat.isRsd
			if isRsd {
				let tunnelReady = await self._heartbeat.ensureRSDTunnel()
				guard tunnelReady else {
					throw IDeviceSwiftError(message: "Missing Pairing")
				}
			} else {
				let connection = await self._heartbeat.checkSocketConnection()
				guard connection.isConnected else {
					throw IDeviceSwiftError(message: "Missing Pairing")
				}
			}
			
			defer {
                if let openFile = fileHandle { _ = afc_file_close(openFile) }
                if let remotePackage, let client = afcClient { try? self._removeOwnedPackage(remotePackage, client: client) }
				afc_client_free(afcClient)
				installation_proxy_client_free(installproxy)
			}
			
			let heartbeat = await self._heartbeat
			
			if heartbeat.isRsd {
				guard let adapter = heartbeat.adapter else {
					throw IDeviceSwiftError(message: "Cannot find RSD adapter")
				}
				
				guard let handshake = heartbeat.handshake else {
					throw IDeviceSwiftError(message: "Cannot find RSD handshake")
				}
	
				guard afc_client_connect_rsd(adapter, handshake, &afcClient) == nil else {
					throw IDeviceSwiftError(message: "Cannot connect to AFC")
				}
			} else {
				guard let provider = heartbeat.provider else {
					throw IDeviceSwiftError(message: "Cannot find TCP provider")
				}
				
				guard afc_client_connect(provider, &afcClient) == nil else {
					throw IDeviceSwiftError(message: "Cannot connect to AFC")
				}
			}
			
            // Recover only our own crash/self-update leftovers; never enumerate or expose other apps' files.
            for path in IDeviceOwnedStaging.paths {
                if let client = afcClient { try? self._removeOwnedPackage(path, client: client) }
            }
			let stagingDir = "PublicStaging"
			
			let afc_make_directory_result =  afc_make_directory(afcClient, stagingDir)
            if let error = afc_make_directory_result {
                defer { idevice_error_free(error) }
                // Pinned idevice 0.1.57: AFC ObjectExists = code 106, sub-code 16.
                guard error.pointee.code == 106 && error.pointee.sub_code == 16 else { throw IDeviceSwiftError(error) }
            }

			
			let remoteDir = "/\(stagingDir)/\(self._uuid).ipa"
            remotePackage = remoteDir
            IDeviceOwnedStaging.add(remoteDir)
			
			let afc_file_open_result = afc_file_open(afcClient, remoteDir, AfcWrOnly, &fileHandle)
			guard afc_file_open_result == nil else {
				throw IDeviceSwiftError(afc_file_open_result)
			}

			
			try await self._updateStatus(with: .sendingPayload)
			
			guard let openedFile = fileHandle else {
				throw IDeviceSwiftError(message: "Missing File Handle")
			}
			
            try await IDeviceFileTransfer.stream(
                from: url,
                checkCancellation: { try Task.checkCancellation() },
                write: { chunk in
                    // Never retain a pointer outside Data.withUnsafeBytes.
                    try chunk.withUnsafeBytes { bytes in
                        guard let pointer = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                            throw IDeviceSwiftError(message: "Empty transfer buffer")
                        }
                        if let error = afc_file_write(openedFile, pointer, chunk.count) {
                            throw IDeviceSwiftError(error)
                        }
                    }
                },
                progress: { value in try? await self._updateUploadProgress(with: value) }
            )
            try Task.checkCancellation()

			let afc_file_close_result = afc_file_close(openedFile)
            fileHandle = nil
			guard afc_file_close_result == nil else {
				throw IDeviceSwiftError(afc_file_close_result)
			}
			
			try await self._updateStatus(with: .installing)
			
			
			if heartbeat.isRsd {
				guard let adapter = heartbeat.adapter else {
					throw IDeviceSwiftError(message: "Cannot find RSD adapter")
				}
				
				guard let handshake = heartbeat.handshake else {
					throw IDeviceSwiftError(message: "Cannot find RSD handshake")
				}

				
				let installation_proxy_connect_rsd_result = installation_proxy_connect_rsd(adapter, handshake, &installproxy)
				guard installation_proxy_connect_rsd_result == nil else {
					throw IDeviceSwiftError(installation_proxy_connect_rsd_result)
				}
			} else {
				guard let provider = heartbeat.provider else {
					throw IDeviceSwiftError(message: "Cannot find TCP provider")
				}
				let installation_proxy_connect_result = installation_proxy_connect(provider, &installproxy)
				guard installation_proxy_connect_result == nil else {
					throw IDeviceSwiftError(installation_proxy_connect_result)
				}
			}

			
			let installError: UnsafeMutablePointer<IdeviceFfiError>? = remoteDir.withCString { cString in
				let context = Unmanaged.passUnretained(self).toOpaque()
				
				if suspend {
					DispatchQueue.main.async {
						UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
					}
				}
				
				return installation_proxy_install_with_callback(
					installproxy,
					cString,
					nil, // options
					Self._installationProgressCallback,
					context
				)
			}
			
			guard installError == nil else {
				throw IDeviceSwiftError(installError)
			}
			
            // Do not report completion while a retrievable IPA remains in AFC staging.
            if let client = afcClient { try self._removeOwnedPackage(remoteDir, client: client) }
            remotePackage = nil
			try await Task.sleep(nanoseconds: 350_000_000)
			try await self._updateStatus(with: .completed(.success(Void())))
        }
        try await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: {
            worker.cancel()
        })
	}
	
    private func _removeOwnedPackage(_ path: String, client: AfcClientHandle) throws {
        if let error = afc_remove_path(client, path) {
            defer { idevice_error_free(error) }
            // The device may already remove the package after successful installation.
            guard error.pointee.code == 106 && error.pointee.sub_code == 8 else { throw IDeviceSwiftError(error) }
        }
        IDeviceOwnedStaging.remove(path)
    }

	private func _updateStatus(with status: InstallerStatusViewModel.InstallerStatus) async throws {
		await MainActor.run {
			self.viewModel.status = status
		}
	}
	
	private func _updateUploadProgress(with status: Double) async throws {
		await MainActor.run {
			self.viewModel.uploadProgress = status
		}
	}
	
	nonisolated static private let _installationProgressCallback: @convention(c) (
		UInt64,
		UnsafeMutableRawPointer?
	) -> Void = { progress, context in
		guard let context = context else { return }
		let installer = Unmanaged<InstallationProxy>.fromOpaque(context).takeUnretainedValue()
		Task {
			try? await installer._updateInstallProgress(with: Double(progress) / 100.0)
		}
	}
	
	private func _updateInstallProgress(with status: Double) async throws {
		await MainActor.run {
			self.viewModel.installProgress = status
		}
	}
}
