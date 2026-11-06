from pathlib import Path
import os,shutil
root=Path.cwd()
out=Path(os.environ['RUNNER_TEMP'])/'xsign-local-server-checks'
(out/'Sources').mkdir(parents=True,exist_ok=True)
for source in ['Feather/Backend/Server/XSignLocalSigningServer.swift',
 'Feather/Backend/Server/XSignLocalSigningJobs.swift','Feather/Backend/Server/XSignLocalRequestAuthentication.swift',
 'Feather/Utilities/XSignPrivateFiles.swift', 'Feather/Utilities/XSignIPAExtractor.swift','Tools/Tests/xsign_local_signing_server_checks.swift',
 'Tools/Tests/xsign_ipa_extraction_checks.swift', 'Tools/Tests/xsign_ota_checks.swift', 'Tools/Tests/xsign_feather_manifest_checks.swift',
 'Feather/Backend/Server/XSignBoundedHTTP.swift', 'Feather/Backend/Server/XSignOTAProtocol.swift',
 'Feather/Backend/Server/XSignOTATLS.swift', 'Feather/Backend/Server/XSignOTAInstaller.swift']:
 shutil.copy2(root/source,out/'Sources'/Path(source).name)
(out/'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "XSignLocalServerChecks", platforms: [.macOS(.v13)],
 dependencies: [
  .package(url: "https://github.com/vapor/vapor.git", exact: "4.104.0"),
  .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.12.3"),
  .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.29.3"),
  .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")],
 targets: [.executableTarget(name: "XSignLocalServerChecks", dependencies: [
  .product(name: "Vapor", package: "vapor"), .product(name: "NIOSSL", package: "swift-nio-ssl"), .product(name: "Crypto", package: "swift-crypto"),
  .product(name: "ZIPFoundation", package: "ZIPFoundation")], path: "Sources")],
 swiftLanguageVersions: [.v5])
''')
shutil.copy2(root/'Feather.xcworkspace/xcshareddata/swiftpm/Package.resolved',out/'Package.resolved')
print(out)
