import Foundation

// Pure rules shared by the update gate, eligibility checks and regression tests.
enum XSignReleaseVersion {
    // Immutable Release URLs distinguish republished builds without inventing versions.
    static func catalogNeedsUpdate(currentVersion:String?,targetVersion:String,currentURL:URL?,targetURL:URL)->Bool {
        guard let currentVersion else { return true }
        if let order=compare(currentVersion,targetVersion) {
            if order != 0 { return order < 0 }
        } else if currentVersion != targetVersion { return true }
        guard let currentURL,currentURL != targetURL,
              targetURL.scheme == "https",targetURL.host?.lowercased() == "github.com",
              targetURL.user == nil,targetURL.password == nil,
              targetURL.path.contains("/releases/download/") else { return false }
        return true
    }
    static func valid(_ value:String)->Bool {
        value.range(of:"^[0-9]{1,9}(\\.[0-9]{1,9}){0,3}$",options:.regularExpression) != nil
    }
    static func compare(_ a:String,_ b:String)->Int? {
        guard valid(a),valid(b) else { return nil }
        let lhs=a.split(separator:".").compactMap { Int($0) },rhs=b.split(separator:".").compactMap { Int($0) }
        for i in 0..<max(lhs.count,rhs.count) {
            let x=i<lhs.count ? lhs[i] : 0,y=i<rhs.count ? rhs[i] : 0
            if x != y { return x<y ? -1 : 1 }
        }
        return 0
    }
    static func isNewer(currentVersion:String,currentBuild:String,targetVersion:String,targetBuild:String?)->Bool {
        guard let comparison=compare(currentVersion,targetVersion) else { return false }
        if comparison != 0 { return comparison<0 }
        guard let build=targetBuild,let comparison=compare(currentBuild,build) else { return false }
        return comparison<0
    }
}

struct XSignSelfUpdateProfile: Sendable {
    let team:String
    let prefix:String
    let bundlePattern:String
    let expiration:Date
    let allDevices:Bool
    let devices:Set<String>
    let developerCertificates:[Data]
    enum Failure: Error { case malformed, incompatible }
    static func read(_ url:URL) throws -> Self {
        let values=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard values.isRegularFile == true,values.isSymbolicLink != true,
              let size=values.fileSize,size<=8_388_608 else { throw Failure.malformed }
        return try decode(Data(contentsOf:url))
    }
    static func decode(_ data:Data) throws -> Self {
        guard data.count<=8_388_608 else { throw Failure.malformed }
        let plist:Data
        if data.starts(with:Data("bplist".utf8)) || data.starts(with:Data("<?xml".utf8)) { plist=data }
        else {
            guard let begin=data.range(of:Data("<?xml".utf8)),
                  let end=data.range(of:Data("</plist>".utf8),in:begin.lowerBound..<data.endIndex) else { throw Failure.malformed }
            plist=data.subdata(in:begin.lowerBound..<end.upperBound)
        }
        guard let root=try PropertyListSerialization.propertyList(from:plist,format:nil) as? [String:Any],
              let team=(root["TeamIdentifier"] as? [String])?.first,!team.isEmpty,
              let expiry=root["ExpirationDate"] as? Date,
              let entitlements=root["Entitlements"] as? [String:Any],
              let appID=entitlements["application-identifier"] as? String ?? entitlements["com.apple.application-identifier"] as? String,
              let prefix=((root["ApplicationIdentifierPrefix"] as? [String] ?? [])+[team]).first(where:{ !$0.isEmpty && appID.hasPrefix($0+".") }) else { throw Failure.malformed }
        let pattern=String(appID.dropFirst(prefix.count+1))
        guard !pattern.isEmpty,!pattern.contains(".."),
              pattern.unicodeScalars.allSatisfy({ CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.*").contains($0) }),
              !pattern.contains("*") || pattern == "*" || (pattern.hasSuffix(".*") && pattern.filter { $0 == "*" }.count==1) else { throw Failure.malformed }
        return Self(team:team,prefix:prefix,bundlePattern:pattern,expiration:expiry,
            allDevices:root["ProvisionsAllDevices"] as? Bool == true,
            devices:Set(root["ProvisionedDevices"] as? [String] ?? []),
            developerCertificates:root["DeveloperCertificates"] as? [Data] ?? [])
    }
    func supports(_ bundleID:String)->Bool {
        if bundlePattern == "*" { return !bundleID.isEmpty }
        if bundlePattern.hasSuffix(".*") { return bundleID.hasPrefix(String(bundlePattern.dropLast())) && bundleID.count>bundlePattern.count-1 }
        return bundleID == bundlePattern
    }
    func canReplace(_ installed:Self,bundleID:String,now:Date=Date())->Bool {
        guard expiration>now,team==installed.team,prefix==installed.prefix,
              supports(bundleID),installed.supports(bundleID) else { return false }
        if allDevices { return true }
        // iOS exposes no reliable generic device UDID. Preserve the installed profile's
        // whole device set when it contains several devices; do not guess one of them.
        return !installed.allDevices && !installed.devices.isEmpty && devices.isSuperset(of:installed.devices)
    }
}
