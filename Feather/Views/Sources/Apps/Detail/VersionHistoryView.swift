//
//  VersionHistoryView.swift
//  Feather
//
//  Created by Nagata Asami on 27/7/25.
//

import SwiftUI
import AltSourceKit

// MARK: - VersionHistoryView
struct VersionHistoryView: View {
	let sourceURL: URL?
	let source: ASRepository
	let app: ASRepository.App
	let versions: [ASRepository.App.Version]
    
    var body: some View {
        List {
            ForEach(Array(versions.enumerated()), id: \.offset) { _, version in
                VStack(alignment: .leading, spacing: 10) {
                    AppVersionInfo(version: version.version, date: version.date?.date,
                        description: version.localizedDescription ?? xsignText("No release notes available"))
                    DownloadButtonView(url: version.downloadURL, provenance: SourceAppProvenance(
                        sourceURL: sourceURL, repository: source, app: app, version: version))
                }
                .padding(.vertical, 6)
            }
        }
        .xsignListBackground()
    }
}
