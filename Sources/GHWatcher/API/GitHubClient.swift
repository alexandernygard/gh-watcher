import Foundation

struct RateLimit: Sendable, Equatable {
    var resource: String
    var limit: Int
    var remaining: Int
    var used: Int
    var reset: Date

    var fraction: Double { limit > 0 ? Double(remaining) / Double(limit) : 1 }
}

enum GitHubError: LocalizedError {
    case unauthorized
    case http(Int, String)
    case rateLimited(Date)
    case graphql(String)
    case decoding(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: "GitHub rejected the token. Please sign in again."
        case .http(let code, let message): "GitHub returned \(code): \(message)"
        case .rateLimited(let reset): "Rate limited until \(reset.formatted(date: .omitted, time: .shortened))."
        case .graphql(let message): message
        case .decoding(let message): "Unexpected response: \(message)"
        case .invalidResponse: "Invalid response from GitHub."
        }
    }
}

struct FetchResult<T> {
    let value: T
    /// False when GitHub answered 304 Not Modified (free against the rate limit) or the body was identical.
    let changed: Bool
    let pollInterval: Int?
}

/// Thin GitHub REST + GraphQL client.
///
/// Every GET is made conditional with the last ETag / Last-Modified we saw for that URL.
/// GitHub does not count 304 responses against the primary rate limit, which is what
/// makes near-realtime polling affordable.
actor GitHubClient {
    nonisolated let token: String
    private let session: URLSession
    private var cache: [String: Cached] = [:]
    private var rateLimitHandler: (@Sendable (RateLimit) -> Void)?

    private struct Cached {
        let etag: String?
        let lastModified: String?
        let data: Data
        let pollInterval: Int?
    }

    static let apiRoot = "https://api.github.com"

    static let snakeDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom(decodeDate)
        return d
    }()

    static let plainDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom(decodeDate)
        return d
    }()

    @Sendable static func decodeDate(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        if let date = try? Date(string, strategy: .iso8601) { return date }
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unparseable date \(string)")
    }

    init(token: String) {
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config)
    }

    func setRateLimitHandler(_ handler: @escaping @Sendable (RateLimit) -> Void) {
        rateLimitHandler = handler
    }

    func clearCache() { cache.removeAll() }

    // MARK: - REST

    func get<T: Decodable>(
        _ path: String,
        query: [String: String] = [:],
        as type: T.Type = T.self,
        snake: Bool = true,
        conditional: Bool = true
    ) async throws -> FetchResult<T> {
        let url = makeURL(path, query)
        var req = request(url)
        let key = url.absoluteString
        let cached = cache[key]
        if conditional, let cached {
            if let etag = cached.etag {
                req.setValue(etag, forHTTPHeaderField: "If-None-Match")
            } else if let lastModified = cached.lastModified {
                req.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
            }
        }
        let (data, http) = try await perform(req)
        let poll = http.value(forHTTPHeaderField: "X-Poll-Interval").flatMap { Int($0) }
        let decoder = snake ? Self.snakeDecoder : Self.plainDecoder

        if http.statusCode == 304, let cached {
            return FetchResult(value: try decode(T.self, cached.data, decoder, path), changed: false, pollInterval: poll ?? cached.pollInterval)
        }
        try check(http, data)
        if conditional {
            cache[key] = Cached(
                etag: http.value(forHTTPHeaderField: "ETag"),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                data: data,
                pollInterval: poll
            )
        }
        return FetchResult(value: try decode(T.self, data, decoder, path), changed: cached?.data != data, pollInterval: poll)
    }

    func getPaged<T: Decodable>(_ path: String, query: [String: String] = [:], maxPages: Int = 5) async throws -> [T] {
        var results: [T] = []
        var next: URL? = makeURL(path, query)
        var page = 0
        while let url = next, page < maxPages {
            let (data, http) = try await perform(request(url))
            try check(http, data)
            results += try decode([T].self, data, Self.snakeDecoder, path)
            next = Self.nextLink(http.value(forHTTPHeaderField: "Link"))
            page += 1
        }
        return results
    }

    /// Unconditional GET returning the raw body. Redirects to other hosts drop the token.
    func raw(_ path: String) async throws -> Data {
        let (data, http) = try await perform(request(makeURL(path, [:])), delegate: StripAuthOnRedirect())
        try check(http, data)
        return data
    }

    @discardableResult
    func send(_ method: String, _ path: String, json: [String: Any]? = nil) async throws -> Data {
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        let (data, http) = try await perform(request(makeURL(path, [:]), method: method, body: body))
        try check(http, data)
        return data
    }

    func send<T: Decodable>(_ method: String, _ path: String, json: [String: Any]? = nil, as type: T.Type) async throws -> T {
        let data = try await send(method, path, json: json)
        return try decode(T.self, data, Self.snakeDecoder, path)
    }

    // MARK: - GraphQL

    func graphql<T: Decodable>(_ query: String, variables: [String: Any] = [:], as type: T.Type = T.self) async throws -> T {
        let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, http) = try await perform(request(URL(string: Self.apiRoot + "/graphql")!, method: "POST", body: body))
        try check(http, data)
        let response = try decode(GraphQLResponse<T>.self, data, Self.plainDecoder, "graphql")
        if let value = response.data {
            if let errors = response.errors, !errors.isEmpty {
                print("[GHWatcher] GraphQL partial errors:", errors.map(\.message))
            }
            return value
        }
        throw GitHubError.graphql(response.errors?.map(\.message).joined(separator: "\n") ?? "Unknown GraphQL error")
    }

    // MARK: - Plumbing

    private func makeURL(_ path: String, _ query: [String: String]) -> URL {
        var components = URLComponents(string: path.hasPrefix("http") ? path : Self.apiRoot + path)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }

    private func request(_ url: URL, method: String = "GET", body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("GHWatcher/1.0", forHTTPHeaderField: "User-Agent")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func perform(_ req: URLRequest, delegate: URLSessionTaskDelegate? = nil) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: req, delegate: delegate)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.invalidResponse }
        if let limit = Self.parseRateLimit(http) { rateLimitHandler?(limit) }
        return (data, http)
    }

    private func check(_ http: HTTPURLResponse, _ data: Data) throws {
        switch http.statusCode {
        case 200..<300:
            return
        case 401:
            throw GitHubError.unauthorized
        case 403, 429:
            if http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0",
               let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(Double.init) {
                throw GitHubError.rateLimited(Date(timeIntervalSince1970: reset))
            }
            throw GitHubError.http(http.statusCode, Self.message(from: data))
        default:
            throw GitHubError.http(http.statusCode, Self.message(from: data))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data, _ decoder: JSONDecoder, _ context: String) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            print("[GHWatcher] Decoding \(T.self) from \(context) failed: \(error)")
            throw GitHubError.decoding("\(context): \(error.localizedDescription)")
        }
    }

    private static func message(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var message = obj["message"] as? String ?? "Unknown error"
            if let errors = obj["errors"] as? [[String: Any]] {
                let details = errors.compactMap { $0["message"] as? String ?? $0["code"] as? String }
                if !details.isEmpty { message += " (" + details.joined(separator: ", ") + ")" }
            }
            return message
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }

    private static func parseRateLimit(_ http: HTTPURLResponse) -> RateLimit? {
        guard let limit = http.value(forHTTPHeaderField: "x-ratelimit-limit").flatMap(Int.init),
              let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining").flatMap(Int.init)
        else { return nil }
        let used = http.value(forHTTPHeaderField: "x-ratelimit-used").flatMap(Int.init) ?? (limit - remaining)
        let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } ?? .now
        let resource = http.value(forHTTPHeaderField: "x-ratelimit-resource") ?? "core"
        return RateLimit(resource: resource, limit: limit, remaining: remaining, used: used, reset: reset)
    }

    private static func nextLink(_ header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";")
            guard pieces.count >= 2, pieces[1].contains("rel=\"next\"") else { continue }
            let raw = pieces[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            return URL(string: raw)
        }
        return nil
    }
}

private final class StripAuthOnRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        var redirected = request
        if request.url?.host != "api.github.com" { redirected.setValue(nil, forHTTPHeaderField: "Authorization") }
        return redirected
    }
}

struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLError]?
}

struct GraphQLError: Decodable {
    let message: String
}
