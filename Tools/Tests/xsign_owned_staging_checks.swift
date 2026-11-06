import Foundation

@main struct OwnedStagingChecks {
    static func main() {
        let original = IDeviceOwnedStaging.paths
        let own = "/PublicStaging/\(UUID().uuidString).ipa"
        IDeviceOwnedStaging.add("/PublicStaging/../../Library/secret.ipa")
        IDeviceOwnedStaging.add("/PublicStaging/another-app.ipa")
        precondition(IDeviceOwnedStaging.paths == original)
        IDeviceOwnedStaging.add(own)
        IDeviceOwnedStaging.add(own)
        precondition(IDeviceOwnedStaging.paths.filter { $0 == own }.count == 1)
        IDeviceOwnedStaging.remove(own)
        precondition(IDeviceOwnedStaging.paths == original)
        print("PASS: only owned UUID staging paths are retained, traversal/unrelated files are rejected")
    }
}
