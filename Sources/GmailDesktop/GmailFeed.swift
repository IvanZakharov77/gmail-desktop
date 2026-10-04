import Foundation
import WebKit

/// Reads the unread count of an account that isn't loaded, from Gmail's Atom feed.
///
/// The request goes only to https://mail.google.com, carries only that account's
/// mail.google.com cookies (the same ones WebKit sends), never follows redirects and
/// stores nothing.
enum GmailFeed {
    struct Result {
        let count: Int
        let latestTitle: String?
        let latestAuthor: String?
    }

    private static let url = URL(string: "https://mail.google.com/mail/u/0/feed/atom")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    @MainActor
    static func fetch(store: WKWebsiteDataStore) async -> Result? {
        let host = "mail.google.com"
        let cookies = await store.httpCookieStore.allCookies().filter { cookie in
            let domain = cookie.domain.lowercased()
            let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            return host == bare || host.hasSuffix("." + bare)
        }
        guard !cookies.isEmpty else { return nil }

        var request = URLRequest(url: url)
        for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue(WebSession.userAgent, forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.host == host,
              let xml = String(data: data, encoding: .utf8),
              let count = first("fullcount", in: xml).flatMap({ Int($0) }) else { return nil }

        let entry = xml.range(of: "<entry>").map { String(xml[$0.upperBound...]) }
        return Result(
            count: count,
            latestTitle: entry.flatMap { first("title", in: $0) }.map(unescape),
            latestAuthor: entry.flatMap { first("name", in: $0) }.map(unescape)
        )
    }

    private static func first(_ tag: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(tag)>"),
              let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex) else { return nil }
        let value = xml[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value.prefix(200))
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Cookies are attached by hand, so a redirect must never carry them elsewhere.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
