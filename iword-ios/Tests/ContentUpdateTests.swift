import XCTest
import IWordDomain
import IWordStorage
@testable import IWord

final class ContentUpdateTests: XCTestCase {
    func testVocabularyGroupsSeparateCategoriesSortNaturallyAndKeepAllSixThousandWords() throws {
        let (_, source) = try ContentInstaller.install(fixture("valid"))
        let seed = try XCTUnwrap(source.first)
        var words = (0..<6000).map { index -> MobileWord in
            var word = seed
            word.id = "word-\(index)"; word.category = index < 3000 ? "required" : "basic"
            word.unit = "Unit \(index % 12 + 1)"; word.order = index; word.inactive = false
            return word
        }
        var retired = seed; retired.id = "retired"; retired.inactive = true; words.append(retired)
        let units = VocabularyUnit.grouped(Array(words.reversed()))
        XCTAssertEqual(units.count, 24)
        XCTAssertEqual(Set(units.map(\.id)).count, 24)
        XCTAssertEqual(units.flatMap(\.words).count, 6000)
        XCTAssertEqual(Array(units.prefix(3).map(\.title)), ["Unit 1", "Unit 2", "Unit 3"])
        XCTAssertEqual(units[11].title, "Unit 12")
        XCTAssertEqual(units[12].category, "basic")
        XCTAssertTrue(units.allSatisfy { $0.words.map(\.order) == $0.words.map(\.order).sorted() })
    }
    private func fixture(_ name: String) -> URL {
        Bundle(for: Self.self).url(forResource: name, withExtension: "zip", subdirectory: "Fixtures")!
    }
    func testInstallerRejectsTraversalBadHashAssociationAndNewVersion() throws {
        for name in ["traversal", "bad-hash", "bad-relation", "new-version"] {
            XCTAssertThrowsError(try ContentInstaller.install(fixture(name)), name)
        }
        let (manifest, words) = try ContentInstaller.install(fixture("valid"))
        XCTAssertEqual(manifest.wordCount, 1); XCTAssertEqual(words.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: FileManager.default.temporaryDirectory.appendingPathComponent("escape.txt").path))
    }
    func testDiskSpaceAndUnsafeIndexAreRejected() throws {
        XCTAssertThrowsError(try ContentInstaller.checkSpace(required: 100, available: 99))
        XCTAssertNoThrow(try ContentInstaller.checkSpace(required: 100, available: 100))
        var item = RemotePackage(packageId: "unit01", revision: "abc", title: "Test", wordCount: 1, audioCount: 1, bytes: 20, sha256: String(repeating: "a", count: 64), minAppVersion: "1.0.0")
        var index = ContentIndex(schemaVersion: 1, catalogId: "catalog", releaseId: "v1", packages: [item])
        XCTAssertNoThrow(try index.validate())
        item.packageId = "../unit01"; index.packages = [item]
        XCTAssertThrowsError(try index.validate())
    }
    func testActualSpringBootGeneratedPackageMatchesNativeInstaller() throws {
        let url = Bundle(for: Self.self).url(forResource: "server-index", withExtension: "json", subdirectory: "Fixtures")!
        let index = try JSONDecoder().decode(ContentIndex.self, from: Data(contentsOf: url)); try index.validate()
        let item = try XCTUnwrap(index.packages.first)
        let source = fixture("server-synthetic")
        let raw = try Data(contentsOf: source)
        XCTAssertEqual(Int64(raw.count), item.bytes); XCTAssertEqual(ContentInstaller.hash(raw), item.sha256)
        let (manifest, words) = try ContentInstaller.install(source)
        XCTAssertEqual(manifest.catalogId, index.catalogId); XCTAssertEqual(manifest.packageId, item.packageId)
        XCTAssertEqual(manifest.revision, item.revision); XCTAssertEqual(words.count, item.wordCount)
        XCTAssertEqual(words.first?.id.count, 64)
    }
    @MainActor func testUnitReplacementPreservesProgressAndFrozenSession() throws {
        let (manifest, values) = try ContentInstaller.install(fixture("valid"))
        var first = values[0]; first.id = "first"; first.revision = "old"
        var withdrawn = first; withdrawn.id = "withdrawn"
        var state = LocalState(); state.words = [first, withdrawn]
        state.progress[first.id] = WordProgress(id: first.id, learned: true)
        state.progress[withdrawn.id] = WordProgress(id: withdrawn.id, learned: true)
        let session = StudySession(mode: "standard", studyDay: "2026-11-11", slot: "morning", steps: [StudyStep(word: first, kind: "recall")])
        state.sessions[session.id] = session; state.profile.activeSessionID = session.id
        var updated = first; updated.revision = "new"; updated.meaning = "Changed"
        LearningModel.mergeContent(manifest: manifest, incoming: [updated], into: &state)
        XCTAssertEqual(state.availableWords.count, 1)
        XCTAssertTrue(state.progress[withdrawn.id]!.learned)
        XCTAssertTrue(state.progress[first.id]!.learned)
        XCTAssertEqual(state.active?.current?.word.revision, "old")
        XCTAssertEqual(state.availableWords.first?.revision, "new")
        XCTAssertEqual(state.profile.installedPackages?[manifest.packageId], manifest.revision)
    }
    func testP1ProfileDecodesAndSixThousandUnchangedWordsNeedNoContentWrites() throws {
        let profile = try JSONDecoder().decode(LocalProfile.self, from: Data(#"{"id":"p1","name":"Test","deviceID":"d","slot":"morning","serverBaseURL":""}"#.utf8))
        XCTAssertNil(profile.installedPackages)
        let (_, words) = try ContentInstaller.install(fixture("valid"))
        var old = LocalState(); old.profile = profile
        old.words = (0..<6000).map { i in var word = words[0]; word.id = String(i); return word }
        old.progress = Dictionary(uniqueKeysWithValues: old.words.map { ($0.id, WordProgress(id: $0.id, learned: true)) })
        var updated = old; updated.profile.slot = "afternoon"
        let start = ProcessInfo.processInfo.systemUptime
        let changes = try updated.changes(from: old)
        XCTAssertEqual(changes.count, 1); XCTAssertEqual(changes.first?.table, .profile)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2.0)
        updated.words[0].meaning = "Changed even if a malformed source reused its revision"
        XCTAssertEqual(try updated.changes(from: old).filter { $0.table == .content }.count, 1)
    }
    func testSessionConnectAndExpiredAuthentication() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        let client = MobileContentClient(base: URL(string: "https://example.invalid/iword/")!, configuration: config)
        try await client.connect(phone: "13800000000", name: "Test")
        do { _ = try await client.index(); XCTFail("401 must not return an index") }
        catch { XCTAssertTrue(error.localizedDescription.contains("过期")) }
    }
    func testCancellationInterruptsNetworkRequest() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        let client = MobileContentClient(base: URL(string: "https://example.invalid/slow/")!, configuration: config)
        let task = Task { try await client.index() }
        try await Task.sleep(nanoseconds: 50_000_000); task.cancel()
        do { _ = try await task.value; XCTFail("cancelled request must fail") } catch {}
    }
}
private final class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.path.contains("/slow/") { return }
        let isIndex = url.path.hasSuffix("/content/index")
        let response = HTTPURLResponse(url: url, statusCode: isIndex ? 401 : 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((url.path.hasSuffix("/enter") ? "{\"needsName\":false}" : "{}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
