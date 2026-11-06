from pathlib import Path
import os

view = Path('Feather/Views/Sources/SourcesView.swift').read_text()
transport = Path('Feather/Views/Sources/SourcesViewModel.swift').read_text()
vault = view[view.index('enum ProtectedSourcesVault {'):view.index('// MARK: - Rich Apple App Store')]
canonical = transport[transport.index('    nonisolated static func canonicalURL'):transport.index('    private func file(')]
selection = view[view.index('    private nonisolated static let defaultCoreTargets:'):view.index('    private nonisolated static var coreTargets:')]
support = '''import Foundation
struct AltSource { var sourceURL: URL?; var identifier: String? }
struct XSignCoreSourceItem { let name: String; let id: String; let url: String }
'''
output = Path(os.environ['RUNNER_TEMP'])/'xsign-source-policy.swift'
policy=Path('Feather/Utilities/XSignDashboardPolicy.swift').read_text()
errors=transport[transport.index('enum XSignCatalogError:'):transport.index('actor XSignCatalogIO {')]
output.write_text(support+errors+policy+'\n'+'enum XSignCatalogIO {\n'+canonical+'}\n'+vault+'enum SourceSelection {\n'+selection+'}\n')
print(output)
