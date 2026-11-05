//
//  Server+Compute.swift
//  feather
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation
import UIKit.UIGraphicsImageRenderer

extension ServerInstaller {
	var plistEndpoint: URL {
		var comps = URLComponents()
		comps.scheme = self.getServerMethod() == 1 ? "http" : "https"
		comps.host = sni()
		comps.path = "/\(id).plist"
		comps.port = port
		return comps.url!
	}

	var payloadEndpoint: URL {
		var comps = URLComponents()
		comps.scheme = self.getServerMethod() == 1 ? "http" : "https"
		comps.host = sni()
		comps.path = "/\(id).ipa"
		comps.port = port
		return comps.url!
	}
	
	var pageEndpoint: URL {
		var comps = URLComponents()
		comps.scheme = self.getServerMethod() == 1 ? "http" : "https"
		comps.host = sni()
		comps.path = "/install"
		comps.port = port
		return comps.url!
	}
	
    var externalServerLink: String {
        var components = URLComponents(string: "https://api.palera.in/genPlist")
        components?.queryItems = [
            URLQueryItem(name: "bundleid", value: app.identifier ?? ""),
            URLQueryItem(name: "name", value: app.name ?? "X-Sign"),
            URLQueryItem(name: "version", value: app.version ?? "1.0"),
            URLQueryItem(name: "fetchurl", value: payloadEndpoint.absoluteString)
        ]
        let encodedQuery = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = encodedQuery
        return components?.url?.absoluteString ?? ""
    }

	var iTunesLink: String {
		_iTunesLink(with: plistEndpoint.absoluteString)
	}
	
	var iTunesLinkExternal: String {
		_iTunesLink(with: externalServerLink)
	}
	
    private func _iTunesLink(with url: String) -> String {
        var components = URLComponents()
        components.scheme = "itms-services"
        components.host = ""
        components.queryItems = [URLQueryItem(name: "action", value: "download-manifest"),
                                 URLQueryItem(name: "url", value: url)]
        let encodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components.percentEncodedQuery = encodedQuery
        return components.url?.absoluteString ?? ""
    }

    // iOS shows the HTTPS manifest origin. The app must not impersonate that
    // origin by changing its local TLS hostname or by accepting an HTML redirect.
    var brandedManifestEndpoint: URL? {
        guard payloadEndpoint.scheme == "https", let bundle = app.identifier, !bundle.isEmpty else { return nil }
        var components = URLComponents(string: "https://x-sign.web.app/native/manifest.plist")
        components?.queryItems = [
            URLQueryItem(name: "bundle", value: bundle),
            URLQueryItem(name: "version", value: app.version ?? "1.0"),
            URLQueryItem(name: "title", value: app.name ?? "X-Sign"),
            URLQueryItem(name: "ipa", value: payloadEndpoint.absoluteString),
            URLQueryItem(name: "icon", value: displayImageSmallEndpoint.absoluteString),
            URLQueryItem(name: "expires", value: String(Int(Date().timeIntervalSince1970) + 600))
        ]
        let encodedQuery = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components?.percentEncodedQuery = encodedQuery
        return components?.url
    }

    @MainActor private static var brandedEndpointUnavailableUntil = Date.distantPast

    @MainActor
    func verifiedBrandedInstallLink() async -> URL? {
        guard Date() >= Self.brandedEndpointUnavailableUntil,
              let manifestURL = brandedManifestEndpoint else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 7
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: manifestURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request), !Task.isCancelled else {
            Self.brandedEndpointUnavailableUntil = Date().addingTimeInterval(30)
            return nil
        }
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 || http.mimeType?.lowercased() == "text/html" {
            Self.brandedEndpointUnavailableUntil = Date().addingTimeInterval(300)
            return nil
        }
        guard http.statusCode == 200,
              http.url?.host == "x-sign.web.app", http.url?.path == "/native/manifest.plist",
              data.count <= 32_768,
              ["application/xml", "text/xml", "application/x-plist"].contains(http.mimeType?.lowercased() ?? ""),
              let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let items = root["items"] as? [[String: Any]], let item = items.first,
              let metadata = item["metadata"] as? [String: Any],
              metadata["bundle-identifier"] as? String == app.identifier,
              metadata["bundle-version"] as? String == (app.version ?? "1.0"),
              let assets = item["assets"] as? [[String: Any]],
              assets.contains(where: { ($0["kind"] as? String) == "software-package" && ($0["url"] as? String) == payloadEndpoint.absoluteString })
        else { return nil }
        return URL(string: _iTunesLink(with: manifestURL.absoluteString))
    }


	var displayImageSmallEndpoint: URL {
		var comps = URLComponents()
		comps.scheme = "https"
		comps.host = sni()
		comps.path = "/app57x57.png"
		comps.port = port
		return comps.url!
	}

	var displayImageLargeEndpoint: URL {
		var comps = URLComponents()
		comps.scheme = "https"
		comps.host = sni()
		comps.path = "/app512x512.png"
		comps.port = port
		return comps.url!
	}
	
	var displayImageSmallData: Data {
		_createIcon(57)
	}
	
	var displayImageLargeData: Data {
		_createIcon(512)
	}
	
	private func _createIcon(_ r: CGFloat) -> Data {
		let renderer = UIGraphicsImageRenderer(size: .init(width: r, height: r))
		let image = renderer.image { ctx in
			UIColor.tintColor.setFill()
			ctx.fill(.init(x: 0, y: 0, width: r, height: r))
		}
		return image.pngData()!
	}

	var html: String {
		"""
		<html style="background-color: black;">
		<script type="text/javascript">window.location="\(iTunesLinkExternal)"</script>
		</html>
		"""
	}

	var installManifest: [String: Any] {[
		"items": [[
			"assets": [
				[
					"kind": "software-package",
					"url": payloadEndpoint.absoluteString,
				],
				[
					"kind": "display-image",
					"url": displayImageSmallEndpoint.absoluteString,
				],
				[
					"kind": "full-size-image",
					"url": displayImageLargeEndpoint.absoluteString,
				],
			],
			"metadata": [
				"bundle-identifier": app.identifier,
				"bundle-version": app.version,
				"kind": "software",
				"title": app.name,
			],
		],],
	]}

	var installManifestData: Data {
		(try? PropertyListSerialization.data(
			fromPropertyList: installManifest,
			format: .xml,
			options: .zero
		)) ?? .init()
	}
}
