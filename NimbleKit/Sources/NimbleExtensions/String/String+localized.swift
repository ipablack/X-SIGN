//
//  String+localized.swift
//  NimbleKit
//
//  Created by samara on 20.03.2025.
//

import Foundation
import SwiftUI

private enum XSignLocalizationBundles {
    static let bundles: [String: Bundle] = Dictionary(uniqueKeysWithValues: ["ar", "en", "ckb"].compactMap { code in
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        return (code, bundle)
    })
}

extension String {
	// from: https://github.com/NSAntoine/Antoine/blob/main/Antoine/Backend/Extensions/Foundation.swift#L43-L55
	// was given permission to use any code from antoine as I like - thank you Serena!~
	
	static public func localized(_ name: String) -> String {
        let code = UserDefaults.standard.string(forKey: "xsign.interfaceLanguage") ?? "ar"
        return localized(name, languageCode: code)
	}

    static public func localized(_ name: String, languageCode: String) -> String {
        let bundles = XSignLocalizationBundles.bundles
        let fallback = bundles["en"]?.localizedString(forKey: name, value: name, table: nil) ?? name
        return bundles[languageCode]?.localizedString(forKey: name, value: fallback, table: nil) ?? fallback
    }
	
	static public func localized(_ name: String, arguments: CVarArg...) -> String {
		String(format: localized(name), arguments: arguments)
	}
	/// Localizes the current string using the main bundle.
	///
	/// - Returns: The localized string.
	public func localized() -> String {
		String.localized(self)
	}
}

extension LocalizedStringKey {
	static public func localized(_ key: String) -> LocalizedStringKey {
		LocalizedStringKey(key)
	}
}
