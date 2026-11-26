import Foundation

@main struct SelfUpdateChecks {
    static func profile(team:String="TEAM",prefix:String="TEAM",bundle:String="*",devices:[String]=["device-a"],all:Bool=false,expires:Date=Date(timeIntervalSince1970:4_000_000_000)) throws -> XSignSelfUpdateProfile {
        let root:[String:Any]=["TeamIdentifier":[team],"ApplicationIdentifierPrefix":[prefix],"Entitlements":["application-identifier":prefix+"."+bundle],"ExpirationDate":expires,"ProvisionsAllDevices":all,"ProvisionedDevices":devices,"DeveloperCertificates":[Data([1,2,3])]]
        return try .decode(PropertyListSerialization.data(fromPropertyList:root,format:.xml,options:0))
    }
    static func main() throws {
        let bundle="com.ipablack.xsign"
        let installed=try profile()
        let matching=try profile()
        precondition(matching.canReplace(installed,bundleID:bundle))
        let wrongTeam=try profile(team:"OTHER")
        precondition(!wrongTeam.canReplace(installed,bundleID:bundle))
        let wrongPrefix=try profile(prefix:"OTHER")
        precondition(!wrongPrefix.canReplace(installed,bundleID:bundle))
        let wrongApp=try profile(bundle:"com.other.app")
        precondition(!wrongApp.canReplace(installed,bundleID:bundle))
        let expired=try profile(expires:Date(timeIntervalSince1970:1))
        precondition(!expired.canReplace(installed,bundleID:bundle))
        let missingDevice=try profile(devices:["device-b"])
        precondition(!missingDevice.canReplace(installed,bundleID:bundle))
        let multi=try profile(devices:["device-a","device-b"])
        precondition(!installed.canReplace(multi,bundleID:bundle))
        precondition(multi.canReplace(installed,bundleID:bundle))
        let enterprise=try profile(devices:[],all:true)
        precondition(enterprise.canReplace(multi,bundleID:bundle))
        precondition(!multi.canReplace(enterprise,bundleID:bundle))
        precondition(XSignReleaseVersion.isNewer(currentVersion:"5.5",currentBuild:"1",targetVersion:"5.5",targetBuild:"2"))
        precondition(!XSignReleaseVersion.isNewer(currentVersion:"5.5",currentBuild:"2",targetVersion:"5.5",targetBuild:"2"))
        precondition(!XSignReleaseVersion.isNewer(currentVersion:"5.5",currentBuild:"1",targetVersion:"5.4",targetBuild:"99"))
        precondition(!XSignReleaseVersion.isNewer(currentVersion:"5.5",currentBuild:"1",targetVersion:"5.5",targetBuild:"bad"))
        precondition(XSignReleaseVersion.isNewer(currentVersion:"5.5",currentBuild:"99",targetVersion:"5.6",targetBuild:nil))
        precondition(XSignReleaseVersion.matchesInstalled(version:"1.0",build:"4",origin:"approved",targetVersion:"1.0",targetBuild:"4",targetOrigin:"approved"))
        precondition(!XSignReleaseVersion.matchesInstalled(version:"1.0",build:"4",origin:"previous-link",targetVersion:"1.0",targetBuild:"4",targetOrigin:"approved"))
        precondition(!XSignReleaseVersion.matchesInstalled(version:"1.0",build:"4",origin:nil,targetVersion:"1.0",targetBuild:nil,targetOrigin:"approved"))
        precondition(!XSignReleaseVersion.matchesInstalled(version:"1.1",build:"4",origin:"approved",targetVersion:"1.0",targetBuild:"4",targetOrigin:"approved"))
        precondition(!XSignReleaseVersion.matchesInstalled(version:"1.0",build:"3",origin:"approved",targetVersion:"1.0",targetBuild:"4",targetOrigin:"approved"))
        let target = "https://example.com/release"
        precondition(XSignReleaseVersion.requiresUpdate(currentVersion:"1.0",currentBuild:"4",installedOrigin:nil,targetVersion:"1.0",targetBuild:"5",targetOrigin:target))
        precondition(!XSignReleaseVersion.requiresUpdate(currentVersion:"1.1",currentBuild:"1",installedOrigin:nil,targetVersion:"1.0",targetBuild:"5",targetOrigin:target))
        precondition(!XSignReleaseVersion.requiresUpdate(currentVersion:"1.0",currentBuild:"6",installedOrigin:"old",targetVersion:"1.0",targetBuild:"5",targetOrigin:target))
        precondition(!XSignReleaseVersion.requiresUpdate(currentVersion:"1.0.0",currentBuild:"5",installedOrigin:nil,targetVersion:"1.0",targetBuild:"5",targetOrigin:target))
        precondition(XSignReleaseVersion.requiresUpdate(currentVersion:"1.0",currentBuild:"5",installedOrigin:"old",targetVersion:"1.0",targetBuild:"5",targetOrigin:target))
        precondition(!XSignReleaseVersion.requiresUpdate(currentVersion:"1.0",currentBuild:"5",installedOrigin:target,targetVersion:"1.0",targetBuild:"5",targetOrigin:target))
        func approved(_ version: String, _ build: String, _ origin: String?, _ strict: Bool) -> Bool {
            XSignReleaseVersion.isApproved(currentVersion: version, currentBuild: build, installedOrigin: origin,
                targetVersion: "1.0", targetBuild: "15", targetOrigin: target, requireOrigin: strict)
        }
        precondition(approved("1.0.0", "15", target, true))
        precondition(approved("1.1", "15", nil, true))
        precondition(approved("1.0", "16", nil, true))
        precondition(XSignReleaseVersion.isApproved(currentVersion: "1.0", currentBuild: "54", installedOrigin: nil,
            targetVersion: "1.0", targetBuild: "47", targetOrigin: target, requireOrigin: true,
            installedRequest: nil, targetRequest: "previous-build"))
        precondition(!approved("1.0", "14", target, true))
        precondition(!approved("1.0", "15", nil, true))
        precondition(!approved("1.0", "15", "different", true))
        precondition(approved("1.0", "15", "different", false))
        precondition(approved("1.0", "15", "", false))
        precondition(XSignReleaseVersion.isApproved(currentVersion: "1.0", currentBuild: "15", installedOrigin: nil,
            targetVersion: "1.0", targetBuild: "15", targetOrigin: target, requireOrigin: true,
            installedRequest: "this-build", targetRequest: "this-build", allowUnstampedIPA: true))
        precondition(!XSignReleaseVersion.isApproved(currentVersion: "1.0", currentBuild: "15", installedOrigin: target,
            targetVersion: "1.0", targetBuild: "15", targetOrigin: target, requireOrigin: false,
            installedRequest: "old-build", targetRequest: "this-build"))
        precondition(!XSignReleaseVersion.isApproved(currentVersion: "1.0", currentBuild: "15", installedOrigin: "old-link",
            targetVersion: "1.0", targetBuild: "15", targetOrigin: target, requireOrigin: true,
            installedRequest: "this-build", targetRequest: "this-build", allowUnstampedIPA: true))
        precondition(XSignReleaseVersion.requiresUpdate(currentVersion: "1.0", currentBuild: "15", installedOrigin: nil,
            targetVersion: "1.0", targetBuild: "15", targetOrigin: target,
            installedRequest: "old-build", targetRequest: "this-build"))
        precondition(XSignReleaseVersion.acceptsPreparedOrigin(nil, targetOrigin: target, requireOrigin: false, targetRequest: nil))
        precondition(XSignReleaseVersion.acceptsPreparedOrigin("", targetOrigin: target, requireOrigin: true, targetRequest: "this-build"))
        precondition(XSignReleaseVersion.acceptsPreparedOrigin(target, targetOrigin: target, requireOrigin: true, targetRequest: nil))
        precondition(!XSignReleaseVersion.acceptsPreparedOrigin(nil, targetOrigin: target, requireOrigin: true, targetRequest: nil))
        precondition(!XSignReleaseVersion.acceptsPreparedOrigin("wrong-link", targetOrigin: target, requireOrigin: false, targetRequest: nil))
        let previous=URL(string:"https://github.com/owner/repo/releases/download/old/app.ipa")!
        let next=URL(string:"https://github.com/owner/repo/releases/download/new/app.ipa")!
        let previousFingerprint = XSignReleaseVersion.downloadFingerprint(previous)
        let nextFingerprint = XSignReleaseVersion.downloadFingerprint(next)
        let signedURL = URL(string: "https://example.com/app.ipa?token=changed")!
        let signedFingerprint = XSignReleaseVersion.downloadFingerprint(signedURL)
        precondition(signedFingerprint?.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil)
        precondition(signedFingerprint == XSignReleaseVersion.downloadFingerprint(signedURL))
        precondition(previousFingerprint != nextFingerprint)
        precondition(XSignReleaseVersion.catalogNeedsUpdate(currentVersion:"2.0",targetVersion:"2.0",currentFingerprint:previousFingerprint,targetURL:next))
        precondition(!XSignReleaseVersion.catalogNeedsUpdate(currentVersion:"2.0",targetVersion:"2.0",currentFingerprint:nextFingerprint,targetURL:next))
        precondition(!XSignReleaseVersion.catalogNeedsUpdate(currentVersion:"3.0",targetVersion:"2.0",currentFingerprint:previousFingerprint,targetURL:next))
        precondition(!XSignReleaseVersion.catalogNeedsUpdate(currentVersion:"2.0",targetVersion:"2.0",currentFingerprint:nil,targetURL:next))
        precondition(!XSignReleaseVersion.catalogNeedsUpdate(currentVersion:"2.0",targetVersion:"2.0",currentFingerprint:previousFingerprint,targetURL:signedURL))
        let protected = URL(string: "https://xsign.example.test/v1/packages/" + String(repeating: "a", count: 64))!
        precondition(XSignReleaseVersion.catalogNeedsUpdate(currentVersion:"2.0",targetVersion:"2.0",currentFingerprint:nextFingerprint,targetURL:protected,isProtectedPackage:true))
        precondition(!XSignReleaseVersion.catalogNeedsUpdate(currentVersion:"2.0",targetVersion:"2.0",currentFingerprint:nextFingerprint,targetURL:protected))
        print("PASS: self-update version/build ordering, team/prefix/bundle preservation, expiry and conservative device coverage")
    }
}
