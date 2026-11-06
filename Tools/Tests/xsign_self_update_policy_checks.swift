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
        let previous=URL(string:"https://github.com/owner/repo/releases/download/old/app.ipa")!
        let next=URL(string:"https://github.com/owner/repo/releases/download/new/app.ipa")!
        precondition(XSignReleaseVersion.catalogNeedsUpdate(currentVersion:"2.0",targetVersion:"2.0",currentURL:previous,targetURL:next))
        precondition(!XSignReleaseVersion.catalogNeedsUpdate(currentVersion:"2.0",targetVersion:"2.0",currentURL:next,targetURL:next))
        precondition(!XSignReleaseVersion.catalogNeedsUpdate(currentVersion:"3.0",targetVersion:"2.0",currentURL:previous,targetURL:next))
        precondition(!XSignReleaseVersion.catalogNeedsUpdate(currentVersion:"2.0",targetVersion:"2.0",currentURL:nil,targetURL:next))
        precondition(!XSignReleaseVersion.catalogNeedsUpdate(currentVersion:"2.0",targetVersion:"2.0",currentURL:previous,targetURL:URL(string:"https://example.com/app.ipa?token=changed")!))
        print("PASS: self-update version/build ordering, team/prefix/bundle preservation, expiry and conservative device coverage")
    }
}
