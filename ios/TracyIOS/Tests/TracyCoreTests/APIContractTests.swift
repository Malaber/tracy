import Foundation
import Testing

@testable import TracyCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

private final class ContractProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        #expect(request.url?.path == "/api/v1/entries/2026-09-29")
        #expect(request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(request.value(forHTTPHeaderField: "If-Match") == "prior-revision")
        #expect(
            request.value(forHTTPHeaderField: "Idempotency-Key") == "00000000-0000-0000-0000-000000000001")
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        let data = Data(
            """
            {"date":"2026-09-29","saved":true,"revision":"new-revision","client_mutation_id":"00000000-0000-0000-0000-000000000001",
            "is_day_off":false,"check_in":"08:00","check_out":"17:00","check_out_next_day":false,
            "breaks":[{"id":1,"mode":"range","duration_minutes":null,"start":"12:00","end":"12:30"}],
            "break_minutes":30,"exact_minutes":510,"billable_minutes":510,"status":"complete","notes":"Saved"}
            """.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func nativeAPIUsesRevisionAndRetryHeadersAndDecodesServerFields() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ContractProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let api = TracyAPI(server: URL(string: "https://tracy.example")!, token: "test-token", session: session)
    let saved = try await api.save(
        "2026-09-29", payload: .init(checkIn: "08:00", checkOut: "17:00"),
        revision: "prior-revision", mutationID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    #expect(saved.clientMutationId == "00000000-0000-0000-0000-000000000001")
    #expect(saved.revision == "new-revision")
    #expect(saved.breaks[0].start == "12:00")
    #expect(saved.exactMinutes == 510)
    let encoded = try JSONSerialization.jsonObject(with: TracyAPI.encode(saved.payload)) as! [String: Any]
    #expect(encoded["check_in"] as? String == "08:00")
    #expect(encoded["check_out_next_day"] as? Bool == false)
    #expect(encoded["revision"] == nil)
}
