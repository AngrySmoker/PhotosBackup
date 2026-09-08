import Foundation

/// Offline `URLProtocol` stand-in for Google. Every test that touches
/// `GPMCClient` drives it through this, so nothing here needs the network or an
/// account.
final class StubProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        static func ok(_ body: Data = Data(), headers: [String: String] = [:]) -> Reply {
            Reply(status: 200, headers: headers, body: body)
        }
        static func text(_ text: String, status: Int = 200) -> Reply {
            Reply(status: status, headers: [:], body: Data(text.utf8))
        }
    }

    private static let lock = NSLock()
    private static var _handler: ((URLRequest) -> Reply)?
    private static var _seen: [URLRequest] = []

    static var handler: ((URLRequest) -> Reply)? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; _seen = []; lock.unlock() }
    }
    static var seen: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _seen }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock(); Self._seen.append(request); let handler = Self._handler; Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let reply = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLRequest {
    var stubPath: String { url?.path ?? "" }
}
