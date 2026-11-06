import Foundation

final class XSignNoHTTPRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum XSignBoundedHTTP {
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 45
        return URLSession(configuration: config, delegate: XSignNoHTTPRedirects(), delegateQueue: nil)
    }

    static func fetch(_ request: URLRequest, using session: URLSession, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let (bytes, raw) = try await session.bytes(for: request)
        guard let response = raw as? HTTPURLResponse, response.expectedContentLength <= Int64(limit) else {
            bytes.task.cancel()
            throw XSignOTAError.invalidManifest
        }
        var data = Data()
        data.reserveCapacity(min(limit, 4096))
        do {
            for try await byte in bytes {
                guard data.count < limit else { throw XSignOTAError.invalidManifest }
                data.append(byte)
            }
        } catch { bytes.task.cancel(); throw error }
        return (data, response)
    }
}
