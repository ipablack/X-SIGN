// swift-tools-version: 5.9
import Foundation
import PackageDescription

let ideviceAssetID = 389721800
let ideviceURL = "https://github.com/jkcoxson/idevice/releases/download/v0.1.57/IDevice.xcframework.zip"
let ideviceChecksum = "40cd5c769b60d1879a96c9caa27666037f9d5321844addec40ae99727b142d10"
let ideviceArchive = "deps/\(ideviceAssetID)/IDevice.xcframework.zip"
let archivePath = Context.packageDirectory + "/" + ideviceArchive
let usePreparedArchive = Context.environment["XSIGN_USE_PREPARED_IDEVICE"] == "1"
	|| FileManager.default.fileExists(atPath: archivePath)
let ideviceTarget: Target = usePreparedArchive
	? .binaryTarget(name: "IDevice", path: ideviceArchive)
	: .binaryTarget(name: "IDevice", url: ideviceURL, checksum: ideviceChecksum)

let package = Package(
	name: "IDeviceKit",
	platforms: [
		.iOS(.v15),
		.macOS(.v12),
	],
	products: [
		.library(
			name: "IDevice",
			targets: ["IDevice"]
		),
		.library(
			name: "IDeviceSwift",
			targets: ["IDeviceSwift"]
		),
	],
	targets: [
		ideviceTarget,
		.target(
			name: "IDeviceSwift",
			dependencies: ["IDevice"]
		),
	]
)
