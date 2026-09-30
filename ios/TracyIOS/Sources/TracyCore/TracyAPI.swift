import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public enum TracyError: LocalizedError, Equatable {
    case invalidServer, expired, conflict
    case rejected(String)
    case server(String)
    public var errorDescription: String? {
        switch self {
        case .invalidServer: "Enter an HTTPS server address without a path, username, or password."
        case .expired: "Your session expired. Sign in again to continue."
        case .conflict: "This day changed on another device. Review both entries before syncing."
        case .server(let message): message
        case .rejected(let message): message
        }
    }
}

public enum ServerAddress {
    public static func parse(_ value: String) throws -> URL {
        guard let parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
            parts.scheme == "https", let host = parts.host, !host.isEmpty,
            parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
            parts.path.isEmpty || parts.path == "/", let url = parts.url
        else {
            throw TracyError.invalidServer
        }
        return url
    }
}

public struct TracyAPI: Sendable {
    public let server: URL
    public let token: String
    private let session: URLSession

    public init(server: URL, token: String, session: URLSession = .shared) {
        self.server = server
        self.token = token
        self.session = session
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(value)
    }

    public func data(
        _ path: String, method: String = "GET", body: Data? = nil,
        query: [URLQueryItem] = [], headers: [String: String] = [:]
    ) async throws -> Data {
        var components = URLComponents(
            url: server.appending(path: "api/v1/" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TracyError.server("The server returned an invalid response.")
        }
        if http.statusCode == 401 { throw TracyError.expired }
        if http.statusCode == 409 { throw TracyError.conflict }
        guard (200..<300).contains(http.statusCode) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = json?["detail"] as? String
            if http.statusCode == 400 || http.statusCode == 422 {
                throw TracyError.rejected(
                    message
                        ?? "This entry could not be accepted. Review its times and breaks, then save it again."
                )
            }
            throw TracyError.server(
                message
                    ?? "The server could not save or load this entry (\(http.statusCode)). Please try again.")
        }
        return data
    }

    public func entry(_ date: String) async throws -> WorkEntry {
        try Self.decoder.decode(WorkEntry.self, from: await data("entries/\(date)"))
    }

    public func save(_ date: String, payload: EntryPayload, revision: String, mutationID: UUID) async throws
        -> WorkEntry
    {
        if let message = payload.validationMessage { throw TracyError.server(message) }
        return try Self.decoder.decode(
            WorkEntry.self,
            from: await data(
                "entries/\(date)", method: "PUT", body: Self.encode(payload),
                headers: ["If-Match": revision, "Idempotency-Key": mutationID.uuidString]))
    }

    public func statistics(period: String = "custom", anchor: String, start: String? = nil) async throws
        -> Statistics
    {
        var query = [
            URLQueryItem(name: "period", value: period), URLQueryItem(name: "anchor", value: anchor),
        ]
        if let start {
            query += [URLQueryItem(name: "start", value: start), URLQueryItem(name: "end", value: anchor)]
        }
        return try Self.decoder.decode(Statistics.self, from: await data("statistics", query: query))
    }
}
