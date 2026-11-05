"""Compile the real parser, transport, cache and indexing logic on the Mac runner."""
from pathlib import Path
import os

root=Path.cwd()
view=(root/'Feather/Views/Sources/SourcesView.swift').read_text()
vm=(root/'Feather/Views/Sources/SourcesViewModel.swift').read_text().replace('import AltSourceKit\n','')
model=(root/'AltSourceKit/Sources/AltSourceKit/Models/ASRepository.swift').read_text()
vault=view[view.index('enum ProtectedSourcesVault {'):view.index('// MARK: - Rich Apple App Store Metadata Model')]
engine=view[view.index('enum AppStoreBilingualEngine {'):view.index('// MARK: - Serial FIFO download queue')]
engine=engine.replace('private struct XSignCatalogSnapshot:', 'struct XSignCatalogSnapshot:')
engine=engine.replace('private nonisolated static func buildSnapshot(', 'fileprivate nonisolated static func buildSnapshot(')
engine=engine.replace('private nonisolated static func makeLaunchPreview(', 'fileprivate nonisolated static func makeLaunchPreview(')
support='''
import Foundation
import SwiftUI
import Combine
import CryptoKit

// Only platform-bound context is stubbed. Parser/transport/index code below is extracted unchanged.
struct AltSource: Hashable, Sendable { let sourceURL: URL?; let identifier: String? }
struct XSignCoreSourceItem: Codable, Equatable, Sendable { let name: String; let id: String; let url: String }
enum AppStoreTheme { static let oceanBlue = Color.blue }
actor AppStoreLiveMetadataBridge { static let shared = AppStoreLiveMetadataBridge(); func invalidateCache() {} }
func xsignSafeURL(_ text: String?) -> URL? { text.flatMap { URL(string: $0) } }
extension Color: Codable {
    public init(from decoder: Decoder) throws { _ = try decoder.singleValueContainer().decode(String.self); self = .blue }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode("005BBB") }
}
extension Array { subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil } }
'''
app=(root/'Feather/FeatherApp.swift').read_text()
models=app[app.index('struct XSignRemoteRoot:'):app.index('// MARK: - مدقق الحماية')]
support=support.replace('struct XSignCoreSourceItem: Codable, Equatable, Sendable { let name: String; let id: String; let url: String }', '')
tests_directory=root/'Tools/Tests'
tests=(tests_directory/'xsign_catalog_checks.swift').read_text()
tests+='\n'+(tests_directory/'xsign_ipa_checks.swift').read_text()
tests+='\n'+(tests_directory/'xsign_storage_checks.swift').read_text()
output=Path(os.environ['RUNNER_TEMP'])/'xsign_catalog_loading_tests.swift'
search=(root/'Feather/Utilities/XSignSearch.swift').read_text()
metadata=(root/'Feather/Utilities/XSignAppMetadata.swift').read_text()
provider=(root/'Feather/Utilities/XSignIPAProvider.swift').read_text()
encryption=(root/'Feather/Utilities/XSignMachOEncryption.swift').read_text()
storage=(root/'Feather/Backend/Storage/Storage.swift').read_text()
output.write_text(support+storage+'\n'+search+'\n'+metadata+'\n'+provider+'\n'+encryption+'\n'+models+'\n'+model+'\n'+vm+'\n'+vault+'\n'+engine+'\n'+tests)
print(output)
