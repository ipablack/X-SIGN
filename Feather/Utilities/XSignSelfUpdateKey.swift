import Foundation
import Security

// Key material stays in the process. Only a Boolean leaves the detached key check.
enum XSignSelfUpdateKey {
    static func matches(_ p12:Data,password:String,allowed:[Data])->Bool {
        guard !p12.isEmpty,p12.count<=8_388_608,!allowed.isEmpty else { return false }
        var imported:CFArray?
        guard SecPKCS12Import(p12 as CFData,[kSecImportExportPassphrase as String:password] as CFDictionary,&imported)==errSecSuccess,
              let entries=imported as? [[String:Any]],
              let value=entries.first?[kSecImportItemIdentity as String],
              CFGetTypeID(value as CFTypeRef)==SecIdentityGetTypeID() else { return false }
        let identity=value as! SecIdentity
        var certificate:SecCertificate?
        guard SecIdentityCopyCertificate(identity,&certificate)==errSecSuccess,let certificate else { return false }
        return allowed.contains(SecCertificateCopyData(certificate) as Data)
    }
}
