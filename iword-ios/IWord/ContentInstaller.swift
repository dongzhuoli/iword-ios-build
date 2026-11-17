import Foundation
import CryptoKit
import ZIPFoundation

struct PackageFile: Codable { var path: String; var sha256: String; var bytes: Int }
struct MobileManifest: Codable {
    var schemaVersion: Int
    var kind: String
    var catalogId: String
    var packageId: String
    var revision: String
    var minAppVersion: String
    var title: String
    var wordCount: Int
    var files: [PackageFile]
}
struct ContentFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum ContentInstaller {
    static func root() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("iWord", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    static func audioURL(_ hash: String) throws -> URL { try root().appendingPathComponent("audio/\(hash).mp3") }
    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func checkSpace(required: Int64, available: Int64? = nil) throws {
        let free = try available ?? (FileManager.default.attributesOfFileSystem(forPath: root().path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard free >= required else { throw ContentFailure(message: "手机可用空间不足，请腾出空间后重试，原词库不会被替换。") }
    }
    static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":") && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty })
    }

    /// Staging is fully checked before immutable audio is installed. Database activation happens later.
    static func install(_ source: URL) throws -> (MobileManifest, [MobileWord]) {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 100 * 1024 * 1024 else { throw ContentFailure(message: "词条包超过本版100MB限制或为空，请按单元拆分。") }
        try checkSpace(required: Int64(size) + 400 * 1024 * 1024)
        let archive = try Archive(url: source, accessMode: .read)
        var extracted: Set<String> = []; var total: UInt64 = 0
        for entry in archive {
            try Task.checkCancellation()
            guard entry.type == .file, safePath(entry.path), extracted.insert(entry.path).inserted else { throw ContentFailure(message: "词条包包含非法路径或重复文件。") }
            total += entry.uncompressedSize
            guard total <= 200 * 1024 * 1024, extracted.count <= 20000 else { throw ContentFailure(message: "词条包展开内容超过限制。") }
            let destination = staging.appendingPathComponent(entry.path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard entry.path == "manifest.json" || entry.path == "entries.jsonl" || entry.path.range(of: "^audio/[a-f0-9]{64}\\.mp3$", options: .regularExpression) != nil else { throw ContentFailure(message: "词条包包含不支持的附件。") }
            let limit: UInt64 = entry.path == "manifest.json" ? 2 * 1024 * 1024 : 30 * 1024 * 1024
            guard entry.uncompressedSize <= limit else { throw ContentFailure(message: "词条包单个文件过大。") }
            fm.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            var actual: UInt64 = 0
            let checksum = try archive.extract(entry) { chunk in
                try Task.checkCancellation()
                actual += UInt64(chunk.count)
                guard actual <= entry.uncompressedSize, actual <= limit else { throw ContentFailure(message: "词条包解压内容超出声明大小。") }
                try handle.write(contentsOf: chunk)
            }
            guard actual == entry.uncompressedSize, checksum == entry.checksum else { throw ContentFailure(message: "词条包解压完整性校验失败。") }
        }
        let manifest = try JSONDecoder().decode(MobileManifest.self, from: Data(contentsOf: staging.appendingPathComponent("manifest.json")))
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        guard manifest.schemaVersion == 1, manifest.kind == "iword-mobile-content", manifest.wordCount > 0, manifest.wordCount <= 10000,
              ContentIndex.identifier(manifest.packageId), ContentIndex.identifier(manifest.revision), !manifest.catalogId.isEmpty,
              manifest.minAppVersion.compare(version, options: .numeric) != .orderedDescending else { throw ContentFailure(message: "词条包格式或最低App版本不兼容。") }
        guard manifest.files.count == extracted.count - 1, Set(manifest.files.map { $0.path }).count == manifest.files.count,
              manifest.files.contains(where: { $0.path == "entries.jsonl" }) else { throw ContentFailure(message: "词条包文件清单不完整。") }
        for file in manifest.files {
            try Task.checkCancellation()
            guard safePath(file.path), file.path != "manifest.json", extracted.contains(file.path) else { throw ContentFailure(message: "词条包缺少清单文件。") }
            let bytes = try Data(contentsOf: staging.appendingPathComponent(file.path))
            guard bytes.count == file.bytes, hash(bytes) == file.sha256 else { throw ContentFailure(message: "文件校验失败：\(file.path)") }
        }
        let text = try String(contentsOf: staging.appendingPathComponent("entries.jsonl"), encoding: .utf8)
        let words = try text.split(whereSeparator: \.isNewline).map { try JSONDecoder().decode(MobileWord.self, from: Data($0.utf8)) }
        guard words.count == manifest.wordCount, Set(words.map { $0.id }).count == words.count else { throw ContentFailure(message: "词条数量或唯一标识校验失败。") }
        for word in words {
            try Task.checkCancellation()
            guard !word.id.isEmpty, word.catalogID == manifest.catalogId, !word.meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  word.word.range(of: "^[a-zA-Z]+$", options: .regularExpression) != nil else { throw ContentFailure(message: "词条字段不完整或拼写格式暂不支持。") }
            if let hash = word.audioHash {
                guard hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                      manifest.files.contains(where: { $0.path == "audio/\(hash).mp3" && $0.sha256 == hash }) else { throw ContentFailure(message: "词条录音引用无效：\(word.word)") }
            }
            guard Set(word.usages.map(\.key)).count == word.usages.count,
                  word.audioUsageKey == nil || word.usages.contains(where: { $0.key == word.audioUsageKey }),
                  word.usages.allSatisfy({ !$0.key.isEmpty && !$0.senses.isEmpty && Set($0.senses.map(\.key)).count == $0.senses.count && $0.senses.allSatisfy({ !$0.key.isEmpty && !$0.meaning.isEmpty }) }) else { throw ContentFailure(message: "词性、义项或录音关联无效：\(word.word)") }
        }
        let audioRoot = try root().appendingPathComponent("audio", isDirectory: true)
        try fm.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        for file in manifest.files where file.path.hasPrefix("audio/") {
            try Task.checkCancellation()
            guard file.path == "audio/\(file.sha256).mp3" else { throw ContentFailure(message: "音频文件名不是内容哈希。") }
            let destination = audioRoot.appendingPathComponent("\(file.sha256).mp3")
            if fm.fileExists(atPath: destination.path), try hash(Data(contentsOf: destination)) == file.sha256 { continue }
            // Atomic replacement, including recovery from an existing damaged file.
            try Data(contentsOf: staging.appendingPathComponent(file.path)).write(to: destination, options: .atomic)
        }
        return (manifest, words)
    }
}
