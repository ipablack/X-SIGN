//
//  CertificateReader.swift
//  Feather
//
//  Created by samara on 16.04.2025.
//

import UIKit
import OSLog

class CertificateReader: NSObject {
	let file: URL?
	var decoded: Certificate?
	
	init(_ file: URL?) {
		self.file = file
		super.init()
		self.decoded = self._readAndDecode()
	}
	
	private func _readAndDecode() -> Certificate? {
		guard let file = file else { return nil }
		
		do {
            let properties = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard properties.isRegularFile == true, properties.isSymbolicLink != true,
                  let size = properties.fileSize, size <= 8_388_608 else { return nil }
			let fileData = try Data(contentsOf: file, options: .mappedIfSafe)
			
			guard let xmlRange = fileData.range(of: Data("<?xml".utf8)) else {
				Logger.misc.error("XML start not found")
				return nil
			}
			
            guard let end = fileData.range(of: Data("</plist>".utf8), in: xmlRange.lowerBound..<fileData.endIndex) else { return nil }
            let xmlData = fileData.subdata(in: xmlRange.lowerBound..<end.upperBound)
			
			let decoder = PropertyListDecoder()
			let data = try decoder.decode(Certificate.self, from: xmlData)
			return data
		} catch {
			Logger.misc.error("Error extracting certificate: \(error.localizedDescription)")
			return nil
		}
	}
}
