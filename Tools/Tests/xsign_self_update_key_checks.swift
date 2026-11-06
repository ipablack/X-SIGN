import Foundation
@main struct SelfUpdateKeyChecks {
    static func main() throws {
        let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["RUNNER_TEMP"]!).appendingPathComponent("xsign-self-update-key")
        let p12=try Data(contentsOf:root.appendingPathComponent("identity.p12"))
        let leaf=try Data(contentsOf:root.appendingPathComponent("cert.der"))
        precondition(XSignSelfUpdateKey.matches(p12,password:"fixture-only",allowed:[leaf]))
        precondition(!XSignSelfUpdateKey.matches(p12,password:"wrong",allowed:[leaf]))
        precondition(!XSignSelfUpdateKey.matches(p12,password:"fixture-only",allowed:[Data([0,1,2])]))
        precondition(!XSignSelfUpdateKey.matches(p12,password:"fixture-only",allowed:[]))
        print("PASS: real PKCS12 import validates password and matches the profile's permitted signing certificate")
    }
}
