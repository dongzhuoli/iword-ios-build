import Foundation

struct RemotePackage: Codable, Identifiable {
    var packageId: String
    var revision: String
    var title: String
    var wordCount: Int
    var audioCount: Int
    var bytes: Int64
    var sha256: String
    var minAppVersion: String
    var id: String { packageId }
}
struct ContentIndex: Codable {
    var schemaVersion: Int
    var catalogId: String
    var releaseId: String
    var packages: [RemotePackage]
    func validate() throws {
        guard schemaVersion == 1, !catalogId.isEmpty, !releaseId.isEmpty, packages.count <= 2000,
              Set(packages.map(\.packageId)).count == packages.count else { throw ContentFailure(message: "服务器词库索引格式不兼容。") }
        for item in packages {
            guard Self.identifier(item.packageId), Self.identifier(item.revision),
                  item.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  item.bytes > 0, item.bytes <= 100 * 1024 * 1024, item.wordCount > 0,
                  item.wordCount <= 10000, item.audioCount >= 0, item.audioCount <= item.wordCount else {
                throw ContentFailure(message: "服务器单元信息无效。")
            }
        }
    }
    static func identifier(_ value: String) -> Bool {
        value.count <= 160 && value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }
}

/// Cookies are confined to this explicit update connection, never to the shared browser or logs.
final class MobileContentClient {
    private let base: URL
    private let session: URLSession
    init(base: URL, configuration: URLSessionConfiguration = .ephemeral) {
        self.base = base
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: TransferDelegate(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    private func request(_ path: String) -> URLRequest {
        var result = URLRequest(url: base.appendingPathComponent(path))
        result.setValue("application/json", forHTTPHeaderField: "Accept")
        return result
    }
    private func checked(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ContentFailure(message: "服务器没有返回有效响应。") }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw ContentFailure(message: "连接已过期，请重新输入手机号并检查更新。")
        case 404: throw ContentFailure(message: "服务器尚未提供此功能，请先更新电脑端程序。地址中不要填写 /study。")
        case 409: throw ContentFailure(message: "服务器已有同编号但内容不同的备份，本次未覆盖，请重新连接后创建新备份。")
        case 413: throw ContentFailure(message: "备份超过服务器大小限制，上传未完成。")
        default: throw ContentFailure(message: "服务器返回 \(http.statusCode)，请稍后重试。")
        }
    }
    func connect(phone: String, name: String) async throws {
        // Obtain a fresh cookie/CSRF token; login rotates the session on the server.
        let (_, initial) = try await session.data(for: request("api/session")); try checked(initial)
        var login = request("api/enter"); login.httpMethod = "POST"
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.httpBody = try JSONSerialization.data(withJSONObject: ["phone": phone, "name": name])
        let (bytes, response) = try await session.data(for: login); try checked(response)
        let body = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        guard body?["needsName"] as? Bool == false else { throw ContentFailure(message: "这个手机号尚无档案，请填写名称后重试。") }
    }
    private var csrf: [String: String] = [:]
    func refreshBackupSession() async throws {
        let (bytes, response) = try await session.data(for: request("api/session")); try checked(response)
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], object["user"] is [String: Any],
              let token = object["csrfToken"] as? String, let header = object["csrfHeader"] as? String else { throw ContentFailure(message: "请先连接服务器账号。") }
        csrf = [header: token]
    }
    func backups() async throws -> [RemoteBackup] {
        let (bytes, response) = try await session.data(for: request("api/mobile/v1/backups")); try checked(response)
        let result = try JSONDecoder().decode([RemoteBackup].self, from: bytes)
        try result.forEach { try $0.validate() }; return result
    }
    func uploadBackup(_ source: URL, id: String, sha256: String, progress: @escaping (Double) -> Void) async throws -> RemoteBackup {
        try await refreshBackupSession()
        var upload = request("api/mobile/v1/backups"); upload.httpMethod = "POST"
        upload.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        upload.setValue(id, forHTTPHeaderField: "X-Backup-ID"); upload.setValue(sha256, forHTTPHeaderField: "X-Backup-SHA256")
        for (header, token) in csrf { upload.setValue(token, forHTTPHeaderField: header) }
        let delegate = BackupUploadDelegate(progress: progress)
        let (bytes, response) = try await session.upload(for: upload, fromFile: source, delegate: delegate); try checked(response)
        let result = try JSONDecoder().decode(RemoteBackup.self, from: bytes); try result.validate()
        let length = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard result.backupID == id, result.sha256 == sha256, result.bytes == length else { throw ContentFailure(message: "服务器确认信息与本次备份不一致，请重试。") }
        return result
    }
    func downloadBackup(_ item: RemoteBackup, progress: @escaping (Double) -> Void) async throws -> URL {
        try item.validate()
        try ContentInstaller.checkSpace(required: item.bytes + 1024 * 1024 * 1024)
        let (temporary, response) = try await session.download(for: request("api/mobile/v1/backups/" + item.backupID), delegate: TransferDelegate(expectedBytes: item.bytes, progress: progress))
        try checked(response); try Task.checkCancellation()
        let count = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard Int64(count) == item.bytes, try BackupArchive.fileHash(temporary) == item.sha256 else { throw ContentFailure(message: "服务器备份下载校验失败，原档案未改变。") }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try FileManager.default.moveItem(at: temporary, to: target); return target
    }
    /// Login cookies are scoped to this connection; configuration is never cached or logged.
    func aiConfiguration() async throws -> AICoachConfiguration {
        var query = request("api/mobile/v1/ai-config")
        query.cachePolicy = .reloadIgnoringLocalCacheData
        let (bytes, response) = try await session.data(for: query)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if (response as? HTTPURLResponse)?.statusCode == 404 {
                throw ContentFailure(message: "电脑端尚未提供AI配置，请先更新后端程序。")
            }
            throw ContentFailure(message: "未能获取AI配置，请检查登录状态和电脑端密钥设置。")
        }
        guard bytes.count <= 64 * 1024 else { throw ContentFailure(message: "AI配置响应过大。") }
        do {
            let value = try JSONDecoder().decode(AICoachConfiguration.self, from: bytes)
            try value.validate()
            return value
        } catch { throw ContentFailure(message: "AI配置不完整，请在电脑端配置中心检查后重试。") }
    }
    func index() async throws -> ContentIndex {
        let (bytes, response) = try await session.data(for: request("api/mobile/v1/content/index")); try checked(response)
        guard bytes.count <= 2 * 1024 * 1024 else { throw ContentFailure(message: "词库索引过大。") }
        let index = try JSONDecoder().decode(ContentIndex.self, from: bytes); try index.validate(); return index
    }
    func download(_ item: RemotePackage, progress: @escaping (Double) -> Void) async throws -> URL {
        let monitor = TransferDelegate(expectedBytes: item.bytes, progress: progress)
        let (temporary, response) = try await session.download(for: request("api/mobile/v1/content/packages/\(item.packageId)/\(item.revision)"), delegate: monitor)
        try checked(response); try Task.checkCancellation()
        let actual = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard actual == item.bytes else { throw ContentFailure(message: "下载不完整，请重试。") }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}

private final class TransferDelegate: NSObject, URLSessionDownloadDelegate {
    let expectedBytes: Int64
    let progress: (Double) -> Void
    init(expectedBytes: Int64 = 100 * 1024 * 1024, progress: @escaping (Double) -> Void = { _ in }) {
        self.expectedBytes = expectedBytes; self.progress = progress
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // A wrong Base URL must not forward phone details/cookies to another origin or login page.
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > expectedBytes || totalBytesExpectedToWrite > expectedBytes { downloadTask.cancel(); return }
        progress(min(1, Double(totalBytesWritten) / Double(max(1, expectedBytes))))
    }
}

struct RemoteBackup: Codable, Identifiable {
    var backupID: String
    var profileID: String
    var deviceID: String
    var createdAt: String
    var receivedAt: String
    var appVersion: String
    var sha256: String
    var bytes: Int64
    var wordCount: Int
    var eventCount: Int
    var id: String { backupID }
    func validate() throws {
        guard UUID(uuidString: backupID) != nil, backupID == backupID.lowercased(), !profileID.isEmpty, !deviceID.isEmpty,
              sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, bytes > 0, bytes <= 500 * 1024 * 1024,
              wordCount >= 0, eventCount >= 0 else { throw ContentFailure(message: "服务器备份信息无效。") }
    }
}
private final class BackupUploadDelegate: NSObject, URLSessionTaskDelegate {
    let progress: (Double) -> Void
    init(progress: @escaping (Double) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress(min(1, Double(totalBytesSent) / Double(max(1, totalBytesExpectedToSend))))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
