import Foundation

@main
struct AppStoreProviderChecks {
    static func main() throws {
        let link = XSignAppStoreReference.parse("https://apps.apple.com/iq/app/example/id123456789?l=ar")!
        precondition(link.id == "123456789" && link.country == "iq")
        for invalid in ["https://apps.apple.com.evil.test/app/id123", "http://apps.apple.com/app/id123", "https://user:password@apps.apple.com/app/id123", "https://example.test/app/id123"] {
            precondition(XSignAppStoreReference.parse(invalid) == nil)
        }
        let endpoint = URL(string: "https://service.example.test/appstore")!
        let request = try XSignIPAProvider.requestURL(endpoint: endpoint, bundleID: "com.example.app", name: "App + Plus & عربي", appStoreID: "123456789")
        let query = URLComponents(url: request, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(query.first { $0.name == "name" }!.value == "App + Plus & عربي")
        precondition(request.absoluteString.contains("%2B"))
        let response = Data(#"{"success":true,"download_url":"https://files.example.test/app.ipa"}"#.utf8)
        let file = try XSignIPAProvider.decode(response, status: 200)
        precondition(file.path == "/app.ipa")
        for status in [401, 403] {
            do { _ = try XSignIPAProvider.decode(response, status: status); preconditionFailure("Unauthorized response accepted") }
            catch XSignIPAProviderError.permissionDenied {}
        }
        for invalid in [#"{"success":true,"download_url":"http://files.example.test/app.ipa"}"#,
                        #"{"success":true,"download_url":"https://user:secret@files.example.test/a.ipa"}"#,
                        #"{"success":true,"download_url":"https://files.example.test/a.ipa#secret"}"#,
                        "<html>Forbidden</html>"] {
            do { _ = try XSignIPAProvider.decode(Data(invalid.utf8), status: 200); preconditionFailure("Invalid download accepted") }
            catch XSignIPAProviderError.invalidResponse {}
        }
        do {
            _ = try XSignIPAProvider.decode(Data(#"{"success":false,"error":"private-server-diagnostic"}"#.utf8), status: 200)
            preconditionFailure("Unavailable app accepted")
        } catch {
            precondition(!error.localizedDescription.contains("private-server-diagnostic"))
        }
        print("PASS: Apple-link validation, encoded request parameters, access rejection and HTTPS download validation")
    }
}
