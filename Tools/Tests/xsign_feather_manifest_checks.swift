import Foundation

private final class FeatherManifestFixtureState: @unchecked Sendable {
    let lock=NSLock()
    private var changed=false
    func setChanged(_ value:Bool) { lock.lock();defer { lock.unlock() };changed=value }
    func response(for request:URLRequest) throws -> Data {
        lock.lock();let broken=changed;lock.unlock()
        let params=Dictionary(uniqueKeysWithValues:URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!.map { ($0.name,$0.value ?? "") })
        let asset:[String:Any] = ["kind":"software-package","url":broken ? "https://unrelated.invalid/replaced.ipa" : params["fetchurl"]!]
        let value:[String:Any] = ["items":[["assets":[asset],"metadata":["bundle-identifier":params["bundleid"]!,"bundle-version":params["version"]!,"kind":"software","title":params["name"]!]]]]
        return try PropertyListSerialization.data(fromPropertyList:value,format:.xml,options:0)
    }
}
private final class FeatherManifestFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let state=FeatherManifestFixtureState()
    override class func canInit(with request:URLRequest)->Bool { request.url?.host == "api.palera.in" }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        do {
            guard request.url?.scheme=="https",request.url?.path=="/genPlist",request.httpBody==nil,
                  request.value(forHTTPHeaderField:"User-Agent")=="XSign/1.0" else { throw URLError(.badURL) }
            let body=try Self.state.response(for:request)
            let response=HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/octet-stream"])!
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:body);client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() {}
}
struct FeatherManifestChecks {
    static func run() async throws {
        let token=String(repeating:"a",count:64)
        let payload=URL(string:"http://127.0.0.1:52345/ota/\(token)/payload.ipa")!
        let descriptor=XSignOTADescriptor(payloadURL:payload,bundleIdentifier:"com.xsign.fixture",bundleVersion:"2.1",title:"تطبيق + & اختبار",expiresAt:Int(Date().timeIntervalSince1970)+600)
        let manifest=try XSignManifestBridge.manifestURL(for:descriptor)
        precondition(manifest.host=="api.palera.in" && manifest.scheme=="https")
        let params=URLComponents(url:manifest,resolvingAgainstBaseURL:false)!.queryItems!
        precondition(params.count==4 && params.first { $0.name=="fetchurl" }?.value == payload.absoluteString)
        precondition(params.first { $0.name=="name" }?.value == "XSign")
        for unsafe in ["http://192.168.1.1:52345/ota/\(token)/payload.ipa","http://127.0.0.1.evil.invalid:52345/ota/\(token)/payload.ipa","https://evil.invalid:52345/ota/\(token)/payload.ipa"] {
            let invalid=XSignOTADescriptor(payloadURL:URL(string:unsafe)!,bundleIdentifier:descriptor.bundleIdentifier,bundleVersion:"2",title:"XSign",expiresAt:descriptor.expiresAt)
            do { _=try XSignManifestBridge.manifestURL(for:invalid);fatalError("Non-loopback address accepted") } catch XSignOTAError.invalidPackage {}
        }
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[FeatherManifestFixtureProtocol.self]
        let session=URLSession(configuration:config);defer { session.invalidateAndCancel() }
        let link=try await XSignManifestBridge.prepare(descriptor,session:session)
        precondition(link.scheme=="itms-services")
        let nested=URLComponents(url:link,resolvingAgainstBaseURL:false)?.queryItems?.first { $0.name=="url" }?.value
        precondition(nested==manifest.absoluteString)
        FeatherManifestFixtureProtocol.state.setChanged(true)
        do { _=try await XSignManifestBridge.prepare(descriptor,session:session);fatalError("Server substituted the IPA URL") }
        catch XSignOTAError.invalidManifest {}
        FeatherManifestFixtureProtocol.state.setChanged(false)
        print("PASS: actual Feather protocol encoding, HTTPS manifest, loopback-only payload, request metadata and response substitution rejection")
    }
}
