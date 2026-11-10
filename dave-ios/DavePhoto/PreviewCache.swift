import Foundation
import CryptoKit

@MainActor final class PreviewCache {
    let limit = 128 * 1024 * 1024
    private let directory: URL
    init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("DavePhotoPreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    private func url(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash)
    }
    func read(_ key: String?) -> Data? { guard let key, !key.isEmpty else { return nil }; return try? Data(contentsOf: url(key)) }
    func used() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        return files.reduce(0) { total, file in total + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    func write(_ data: Data, key: String?) throws {
        guard let key, !key.isEmpty else { return }
        let target = url(key), old = ((try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard used() - old + data.count <= limit else { throw BridgeError(message: "设备缓存已达 128 MB，请先清理缓存。") }
        try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func clear() throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files { try FileManager.default.removeItem(at: file) }
    }
}

