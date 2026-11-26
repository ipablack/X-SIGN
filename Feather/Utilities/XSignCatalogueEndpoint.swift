import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum XSignCatalogueEndpoint {
    nonisolated static let ownerURL = URL(string: "xsign-catalog://owner")!
    nonisolated static let ownerID = "xsign.core.owned"
    nonisolated static let primaryID = "xsign.core.primary"
    nonisolated static let iosBoomID = "xsign.iosboom.public"

    nonisolated static let publicCatalogue = publicFile(repository: "repo", path: ["repo.json"])
    nonisolated static let soonSnapshot = publicFile(repository: "repo", path: ["public", "sources", "ipasoon.json"])
    // Keep the existing Studio source URL as the identifier for device-side aggregation.
    nonisolated static let iosBoomCatalogue = publicFile(repository: "repo", path: ["sources", "iosboom-public.json"])
    nonisolated static let iosBoomFeeds = [
        https(host: "repository.apptesters.org", path: "/"),
        https(host: "raw.githubusercontent.com", path: "/drphe/KhoIPA/main/upload/ipaomtk.json"),
        https(host: "raw.githubusercontent.com", path: "/M1noa/Sideload-Tools/main/merged-apps-original-links-no-pal.json")
    ]

    private nonisolated static func publicFile(repository: String, path: [String]) -> URL {
        https(host: "raw.githubusercontent.com", path: (["", "ipablack", repository, "main"] + path).joined(separator: "/"))
    }

    private nonisolated static func https(host: String, path: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        return components.url!
    }
    nonisolated static func ownerRequest(settings: Bool) -> URLRequest {
        let url = settings ? publicFile(repository: "repo", path: ["xsign-config.json"]) : publicCatalogue
        return URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    }

    nonisolated static func alternatePublicRequest(for url: URL) -> URLRequest? {
        let settings = ownerRequest(settings: true).url
        guard url == publicCatalogue || url == soonSnapshot || url == settings else { return nil }
        let file = url.pathComponents.dropFirst(4).joined(separator: "/")
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "api.github.com"
        parts.path = "/repos/ipablack/repo/contents/" + file
        parts.queryItems = [URLQueryItem(name: "ref", value: "main")]
        guard let target = parts.url else { return nil }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        return request
    }

    nonisolated static func packageRequest(_ request: URLRequest) throws -> URLRequest {
        guard let url = request.url, XSignManagedSource.httpsURL(url.absoluteString) != nil else {
            throw URLError(.unsupportedURL)
        }
        return request
    }

    nonisolated static func isOriginalSoon(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "appiraq.com" && url.path == "/source.php" &&
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(
                URLQueryItem(name: "action", value: "getAll")) == true
    }

    nonisolated static func archivedSoon(for url: URL, sourceID: String?) -> URL? {
        guard isOriginalSoon(url), sourceID == nil || sourceID == primaryID else { return nil }
        return soonSnapshot
    }

    nonisolated static func mayRedirect(_ task: URLSessionTask, to request: URLRequest) -> Bool {
        task.originalRequest?.value(forHTTPHeaderField: "Authorization") == nil &&
            task.originalRequest?.httpMethod != "POST" &&
            request.url.flatMap { XSignManagedSource.httpsURL($0.absoluteString) } != nil
    }
}

final class XSignCatalogRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(XSignCatalogueEndpoint.mayRedirect(task, to: request) ? request : nil)
    }
}
