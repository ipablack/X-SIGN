//
//  DylibHandler.swift
//  feather
//
//  Created by samara on 8/17/24.
//  Copyright (c) 2024 Samara M (khcrysalis)
//

import Foundation
import Zsign
import OSLog

class TweakHandler {
	private let _fileManager = FileManager.default
	private var _urlsToInject: [URL] = []
	private var _injectedPaths: [String] = []

	private let _app: URL
	private var _options: Options
	private var _urls: [URL]

	init(
		app: URL,
		options: Options = OptionsManager.shared.options
	) {
		self._app = app
		self._options = options
		self._urls = options.injectionFiles
	}
	
	private func _checkEllekit() async throws {
		let frameworksPath = _app.appendingPathComponent("Frameworks").appendingPathComponent("CydiaSubstrate.framework")

		func addEllekit() async throws {
			if let ellekitURL = Bundle.main.url(forResource: "ellekit", withExtension: "deb") {
				self._urls.insert(ellekitURL, at: 0)
			} else if _options.experiment_replaceSubstrateWithEllekit {
                throw CocoaError(.fileNoSuchFile)
			}
			
			try _fileManager.createDirectoryIfNeeded(at: _app.appendingPathComponent("Frameworks"))
		}
		// we should check if CydiaSubstrate.framework exists, if it doesn't
		// just add ellekit
		// experiment_replaceSubstrateWithEllekit:
		// 	for this version, we need to replace CydiaSubstrate.framework with
		//	our own version containing ElleKit
		// other:
		// 	just return if it exists, should work fine
		if _fileManager.fileExists(atPath: frameworksPath.path) {
			if _options.experiment_replaceSubstrateWithEllekit {
				Logger.misc.info("Attempting to replace Substrate with ElleKit")
				try _fileManager.removeFileIfNeeded(at: frameworksPath)
				try await addEllekit()
			} else {
				return
			}
		} else {
			guard !_urls.isEmpty else { return }
			try await addEllekit()
		}
	}

	public func getInputFiles() async throws {
		Logger.misc.info("Attempting to inject")
		
		if !_options.experiment_replaceSubstrateWithEllekit {
			guard !_urls.isEmpty else { return }
		}

		try await _checkEllekit()

        let baseTmpDir = XSignPrivateFiles.workDirectory(prefix: "InjectionArchive")
        try XSignPrivateFiles.createDirectory(baseTmpDir)
        defer { try? _fileManager.removeItem(at: baseTmpDir) }
		
		// check for appropriate files, if theres debs
		// it will extract then add a url, if theres no url, i.e.
		// you haven't added a deb, it will skip
		for url in _urls {
            try Task.checkCancellation()
			switch url.pathExtension.lowercased() {
			case "dylib":
				try await _handleDylib(at: url)
			case "deb":
				let directory = try await _handleDeb(at: url, baseTmpDir: baseTmpDir)
                _urlsToInject.removeAll(keepingCapacity: true)
                try await _handleDirectories(at: [directory])
                guard !_urlsToInject.isEmpty else {
                    throw NSError(domain: "XSign.Injection", code: 4, userInfo: [NSLocalizedDescriptionKey:
                        "حزمة \(url.lastPathComponent) لا تحتوي إضافات مدعومة لهذا المسار."])
                }
                try await _handleExtractedDirectoryContents(at: _urlsToInject)
            case "framework":
                try await _installFramework(url)
			default:
                throw CocoaError(.fileReadCorruptFile)
			}
		}
		
        if _options.injectIntoExtensions && !_injectedPaths.isEmpty { try _injectIntoAllExtensions() }
	}
	
	// finally, handle extracted contents
	private func _handleExtractedDirectoryContents(at urls: [URL]) async throws {
		for url in urls {
			switch url.pathExtension.lowercased() {
			case "dylib":
				try await _handleDylib(at: url)
			case "framework":
                try await _installFramework(url)
			case "bundle":
				let destinationURL = _app.appendingPathComponent(url.lastPathComponent)
				try _fileManager.moveFileIfNeeded(from: url, to: destinationURL)
			default:
				Logger.misc.warning("Unsupported file type: \(url.lastPathComponent), skipping.")
			}
		}
	}
	
	// Inject imported dylib file
	private func _handleDylib(at url: URL) async throws {
		var destinationURL = _app
		var injectFolder = _options.injectFolder
		
		// check for "/Frameworks/", then append the destinationUrl
		if _options.injectFolder == .frameworks {
			destinationURL = destinationURL.appendingPathComponent("Frameworks")
		}
		
		// We check for "@rpath" and "/Frameworks/", if they're both enabled force
		// the inject folder to be root "/" instead, as the @rpath is already in
		// frameworks
		if
			_options.injectPath == .rpath && _options.injectFolder == .frameworks
		{
			injectFolder = .root
		}
		
		destinationURL = destinationURL.appendingPathComponent(url.lastPathComponent)
		
        let type = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard type.isRegularFile == true, type.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
        try _fileManager.createDirectoryIfNeeded(at: destinationURL.deletingLastPathComponent())
        // Keep the selected copy available for retries if a later signing stage fails.
        try _fileManager.copyItem(at: url, to: destinationURL)
        guard let appexe = Bundle(url: _app)?.executableURL else { throw SigningFileHandlerError.appNotFound }
        guard try !XSignMachOEncryption.isEncrypted(executable: destinationURL) else { throw CocoaError(.fileReadCorruptFile) }
		
		// change paths because some tweaks hardlink, which is not ideal.
		// this is not a good solution, at most this would work for basic tweaks
		// we recommend you use newer theos to compile, and make sure it works
		// using the ellekit framework
		_ = Zsign.changeDylibPath(
			appExecutable: destinationURL.path,
			for: "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
			with: "@rpath/CydiaSubstrate.framework/CydiaSubstrate"
		)
		// inject if there's a valid app main executable
        try addLoadCommand(to: appexe, path: "\(_options.injectPath.rawValue)\(injectFolder.rawValue)\(destinationURL.lastPathComponent)")
        let relative = _options.injectFolder == .frameworks ? "Frameworks/" + destinationURL.lastPathComponent : destinationURL.lastPathComponent
        _injectedPaths.append(relative)
	}
	
    private func _installFramework(_ imported: URL) async throws {
        try XSignIPAExtractor.validateTree(imported)
        let framework = _app.appendingPathComponent("Frameworks").appendingPathComponent(imported.lastPathComponent)
        try _fileManager.createDirectoryIfNeeded(at: framework.deletingLastPathComponent())
        try _fileManager.removeFileIfNeeded(at: framework)
        try _fileManager.copyItem(at: imported, to: framework)
		guard
			let fexe = Bundle(url: framework)?.executableURL,
			let appexe = Bundle(url: _app)?.executableURL
		else {
            throw CocoaError(.fileReadCorruptFile)
		}
        guard try !XSignMachOEncryption.isEncrypted(executable: fexe) else { throw CocoaError(.fileReadCorruptFile) }
		
		// change paths because some tweaks hardlink, which is not ideal.
		// this is not a good solution, at most this would work for basic tweaks
		// we recommend you use newer theos to compile, and make sure it works
		// using the ellekit framework
		_ = Zsign.changeDylibPath(
			appExecutable: fexe.path,
			for: "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
			with: "@rpath/CydiaSubstrate.framework/CydiaSubstrate"
		)
		// inject if there's a valid app main executable
        let relative = "Frameworks/\(framework.lastPathComponent)/\(fexe.lastPathComponent)"
        try addLoadCommand(to: appexe, path: "@executable_path/" + relative)
        _injectedPaths.append(relative)
	}

    private func addLoadCommand(to executable: URL, path: String) throws {
        guard Zsign.injectDyLib(appExecutable: executable.path, with: path) else {
            throw NSError(domain: "XSign.Injection", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "تعذّر ربط \(URL(fileURLWithPath: path).lastPathComponent) بالملف التنفيذي \(executable.lastPathComponent)."])
        }
    }
	
	// Extracy imported deb file
	private func _handleDeb(at url: URL, baseTmpDir: URL) async throws -> URL {
		let uniqueSubDir = baseTmpDir.appendingPathComponent(UUID().uuidString)
		try _fileManager.createDirectoryIfNeeded(at: uniqueSubDir)
		
        let archive = try AR(with: url).member(named: [
            "data.tar.lzma", "data.tar.gz", "data.tar.xz", "data.tar.bz2", "data.tar"
        ])
        var fileToProcess = uniqueSubDir.appendingPathComponent(archive.name)
        try archive.data.write(to: fileToProcess)
        if archive.name != "data.tar" { try extractFile(at: &fileToProcess) }
        try extractFile(at: &fileToProcess)
        return fileToProcess
	}
	
	// Read extracted deb file, locate all neccessary contents to copy over to the .app
	private func _handleDirectories(at urls: [URL]) async throws {
		enum DirectoryType: String {
			case frameworks = "Frameworks"
			case dynamicLibraries = "MobileSubstrate/DynamicLibraries"
			case applicationSupport = "Application Support"
		}
		
		let directoryPaths: [DirectoryType: [String]] = [
			.frameworks: ["Library/Frameworks/", "var/jb/Library/Frameworks/"],
			.dynamicLibraries: ["Library/MobileSubstrate/DynamicLibraries/", "var/jb/Library/MobileSubstrate/DynamicLibraries/"],
			.applicationSupport: ["Library/Application Support/", "var/jb/Library/Application Support/"]
		]
				
		for baseURL in urls {
			for (directoryType, paths) in directoryPaths {
				for path in paths {
					let directoryURL = baseURL.appendingPathComponent(path)
					
					guard _fileManager.fileExists(atPath: directoryURL.path) else {
						Logger.misc.warning("Directory does not exist: \(directoryURL.path). Skipping.")
						continue
					}
					
					switch directoryType {
					case .dynamicLibraries:
						let dylibFiles = try await _locateDylibFiles(in: directoryURL)
						_urlsToInject.append(contentsOf: dylibFiles)
						
					case .frameworks:
						let frameworkDirectories = try await _locateFrameworkDirectories(in: directoryURL)
						_urlsToInject.append(contentsOf: frameworkDirectories)
						
					case .applicationSupport:
						try await _searchForBundles(in: directoryURL)
					}
				}
			}
		}
	}

	// Discovers all .appex bundles in the app's PlugIns and Extensions directories
	private func _discoverAppExtensions() -> [URL] {
		var extensions: [URL] = []
		
		let plugInsPath = _app.appendingPathComponent("PlugIns")
		let extensionsPath = _app.appendingPathComponent("Extensions")
		
		for directory in [plugInsPath, extensionsPath] {
			guard _fileManager.fileExists(atPath: directory.path) else { continue }
			
			do {
				let contents = try _fileManager.contentsOfDirectory(
					at: directory,
					includingPropertiesForKeys: nil,
					options: [.skipsHiddenFiles]
				)
				
				let appexBundles = contents.filter { url in
					url.pathExtension.lowercased() == "appex" && url.hasDirectoryPath
				}
				
				extensions.append(contentsOf: appexBundles)
			} catch {
				Logger.misc.warning("Failed to enumerate \(directory.path): \(error.localizedDescription)")
			}
		}
		
		return extensions
	}

    private func _injectIntoAllExtensions() throws {
        for directory in _discoverAppExtensions() {
            guard let executable = Bundle(url: directory)?.executableURL else {
                throw CocoaError(.fileReadCorruptFile)
            }
            for path in _injectedPaths {
                try addLoadCommand(to: executable, path: "@executable_path/../../" + path)
            }
        }
    }

}

// MARK: - Find correct files in debs
extension TweakHandler {
	private func _searchForBundles(in directory: URL) async throws {
		let fileManager = FileManager.default
		let allFiles = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

		let bundleDirectories = allFiles.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.pathExtension.lowercased() == "bundle" && url.hasDirectoryPath && !isSymlink
		}
		
		for bundleURL in bundleDirectories {
			_urlsToInject.append(bundleURL)
		}
		
		let directoriesToSearch = allFiles.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.hasDirectoryPath && !bundleDirectories.contains(url) && !isSymlink
		}
		
		for dirURL in directoriesToSearch {
			try await _searchForBundles(in: dirURL)
		}
	}

	private func _locateDylibFiles(in directory: URL) async throws -> [URL] {
		let fileManager = FileManager.default
		let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])

		let dylibFiles = files.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.pathExtension.lowercased() == "dylib" && !isSymlink
		}
		
		return dylibFiles
	}

	private func _locateFrameworkDirectories(in directory: URL) async throws -> [URL] {
		let fileManager = FileManager.default
		let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

		let frameworkDirectories = files.filter { url in
			let attributes = try? fileManager.attributesOfItem(atPath: url.path)
			let isSymlink = attributes?[.type] as? FileAttributeType == .typeSymbolicLink
			return url.pathExtension.lowercased() == "framework" && url.hasDirectoryPath && !isSymlink
		}
		
		return frameworkDirectories
	}
}

enum TweakHandlerError: Error {
	case unsupportedFileExtension(String)
	case decompressionFailed(String)
	case missingFile(String)
	case noAccess
}
