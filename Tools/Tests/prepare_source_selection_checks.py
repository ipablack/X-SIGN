from pathlib import Path
import os

view = Path('Feather/Views/Sources/SourcesView.swift').read_text()
transport = Path('Feather/Views/Sources/SourcesViewModel.swift').read_text()
vault = view[view.index('enum ProtectedSourcesVault {'):view.index('// MARK: - Rich Apple App Store')]
catalog_io = transport[transport.index('struct XSignRepositoryRecord:'):].replace('AppStoreCacheManager.', 'SourceSelection.')
selection = view[view.index('    private nonisolated static let defaultCoreTargets:'):view.index('    @discardableResult\n    func configureManagedSources')]
support = '''import Foundation
struct AltSource { var sourceURL: URL?; var identifier: String? }
struct XSignCoreSourceItem { let name: String; let id: String; let url: String }
'''
output = Path(os.environ['RUNNER_TEMP'])/'xsign-source-policy.swift'
policy=Path('Feather/Utilities/XSignDashboardPolicy.swift').read_text()
item = view[view.index('struct AppStoreAppItem:'):view.index('// MARK: - Editorial Instruction Model')]
# Use the production value type without compiling the surrounding Core Data code.
source_metadata = Path('Feather/Backend/Storage/Storage+SourceMetadata.swift').read_text()
provenance_start = source_metadata.index('struct SourceAppProvenance:')
provenance_end = source_metadata.index('enum SourceLinkedAppKind:', provenance_start)
provenance = source_metadata[provenance_start:provenance_end]
category_start = view.index('enum AppStore2026Category:')
category_end = view.index('@MainActor\nfinal class AppStoreCacheManager:', category_start)
builder_start = view.index('    private nonisolated static func buildSnapshot(')
launch_start = view.index('    private nonisolated static func launchApps(')
launch_end = view.index('    private nonisolated static func makeLaunchPreview(', launch_start)
builder_end = view.index('// MARK: - Serial FIFO download queue', builder_start)
bilingual = view[view.index('enum AppStoreBilingualEngine'):view.index('struct AppStoreAppItem:')]
news = view[view.index('struct TodayEditorialInstruction:'):category_start]
search = Path('Feather/Utilities/XSignSearch.swift')
support += """import SwiftUI
enum AppStoreTheme { static let oceanBlue = Color.blue }
func xsignSafeURL(_ raw: String?) -> URL? { raw.flatMap(URL.init(string:)) }
"""
store_layout = Path('Feather/Views/Sources/XSignConfiguredStoreView.swift').read_text()
layout_start = store_layout.index('private struct XSignStoreLayout:')
layout_end = store_layout.index('private struct XSignClassicStoreSection:', layout_start)
layout = store_layout[layout_start:layout_end].replace('private struct XSignStore', 'struct XSignStore')
queue_start = view.index('struct XSignSerialQueue<Element>')
queue_end = view.index('// Collapse byte-level KVO callbacks', queue_start)
output.write_text(support + provenance + policy + '\n' + catalog_io + vault +
    'enum SourceSelection {\n' + selection + '}\n' + search.read_text() + '\n' + bilingual + item + news +
    view[category_start:category_end].replace('private struct XSignCatalogSnapshot', 'struct XSignCatalogSnapshot') + 'enum XSignTestCatalogue {\n' +
    view[launch_start:launch_end] + view[builder_start:builder_end].replace('    private nonisolated static func buildSnapshot', '    static func buildSnapshot', 1)
    + view[queue_start:queue_end] + layout)
print(output)
