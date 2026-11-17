import XCTest
@testable import IWord

final class MobileBackupClientTests: XCTestCase {
    func testManualUploadUsesCSRFAndValidatesServerReceipt() async throws {
        for badReceipt in [false, true] {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [BackupStubProtocol.self]
            let base = URL(string: "https://example.invalid/" + (badReceipt ? "bad/" : "good/"))!
            let client = MobileContentClient(base: base, configuration: configuration)
            try await client.connect(phone: "13800000000", name: "Test")
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data(repeating: 7, count: 32).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let id = "11111111-1111-4111-8111-111111111111", hash = String(repeating: "a", count: 64)
            do {
                let receipt = try await client.uploadBackup(file, id: id, sha256: hash) { _ in }
                if badReceipt { XCTFail("Mismatched receipt must be rejected") }
                XCTAssertEqual(receipt.backupID, id)
                let listed = try await client.backups()
                XCTAssertEqual(listed.count, 1)
            } catch {
                if !badReceipt { throw error }
                XCTAssertTrue(error.localizedDescription.contains("不一致"))
            }
        }
    }
}
private final class BackupStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        var body: Any = [String: String]()
        if url.path.hasSuffix("/session") {
            body = ["user": ["id": 1], "csrfToken": "test-token", "csrfHeader": "X-CSRF-TOKEN"] as [String: Any]
        } else if url.path.hasSuffix("/enter") {
            body = ["needsName": false]
        } else {
            let receipt: [String: Any] = ["backupID": "11111111-1111-4111-8111-111111111111", "profileID": "profile", "deviceID": "device",
                "createdAt": "2026-11-11T00:00:00Z", "receivedAt": "2026-11-11T00:00:00Z", "appVersion": "1.0.0",
                "sha256": String(repeating: "a", count: 64), "bytes": url.path.contains("/bad/") ? 31 : 32, "wordCount": 1, "eventCount": 1]
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-CSRF-TOKEN"), "test-token")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/zip")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Backup-ID"), receipt["backupID"] as? String)
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Backup-SHA256"), receipt["sha256"] as? String)
                body = receipt
            } else { body = [receipt] }
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
