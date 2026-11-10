import Foundation
import SwiftUI

struct PhotoTarget: Decodable, Identifiable, Hashable { let id: Int; let title: String }
struct PhotoPerson: Decodable, Identifiable, Hashable { let key: String; let count: Int; var id: String { key } }
struct PhotoItem: Decodable, Identifiable, Hashable {
    let id: Int; let name: String; let album: String; let width: Int?; let height: Int?; let cacheKey: String?
}
struct FacePerson: Decodable, Identifiable, Hashable { let id: String; let name: String; let samples: Int }
struct FaceScan: Decodable { let run: String; let total: Int; let processed: Int; let matched: Int; let unmatched: Int; let review: Int; let failed: Int; let done: Bool }
struct PreviewInfo: Decodable { let revision: String; let name: String; let width: Int; let height: Int; let small: Bool }
struct PreloadInfo: Decodable { let active: Bool; let total: Int; let done: Int; let failed: Int }
struct WorkState: Decodable {
    let busy: Bool; let readingAlbum: Bool; let canStop: Bool; let targetId: Int?; let status: String
    let folder: String; let lastFolder: String?; let person: String?; let libraryGeneration: Int
    let people: [PhotoPerson]; let photos: [PhotoItem]; let faceConfigured: Bool; let facePeople: [FacePerson]
    let faceScan: FaceScan?; let preview: PreviewInfo?; let preload: PreloadInfo?; let log: [String]
}
struct FaceItem: Decodable, Identifiable { let id: Int; let name: String; let group: String; let error: String?; let thumbnail: String?; let reviewable: Bool }
struct FaceResultPage: Decodable { let items: [FaceItem]; let next: Int; let done: Bool }
struct ThumbItem: Decodable { let id: Int; let thumbnail: String?; let error: String? }
struct ThumbPage: Decodable { let items: [ThumbItem] }
struct Handoff: Decodable { let token: String; let total: Int }
struct OriginalChunk: Decodable { let total: Int; let data: String; let `extension`: String; let width: Int; let height: Int }
struct BridgeError: LocalizedError { let message: String; var errorDescription: String? { message } }

@MainActor final class PhotoBridge: ObservableObject {
    @Published var connection = "正在连接"
    @Published var connected = false
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]
    private var generation = UUID()
    private let endpoint = URL(string: "wss://dave-photo.yyc1166.ccwu.cc/ws")!

    func start() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--offline-preview") { connection = "离线预览"; return }
        #endif
        guard socket == nil else { return }
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: endpoint); task.maximumMessageSize = 16 * 1024 * 1024
        socket = task; generation = UUID(); let current = generation
        connection = "正在连接"; task.resume()
        reader = Task { [weak self] in await self?.receiveLoop(task, current: current) }
        Task { [weak self] in
            do { try await task.send(.string("{\"type\":\"auth\",\"role\":\"browser\",\"secret\":\"\"}")) }
            catch { self?.disconnected(current, reason: "无法连接远程服务") }
        }
    }
    func stop() {
        generation = UUID(); reconnect?.cancel(); reconnect = nil; reader?.cancel(); reader = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil; connected = false; connection = "连接已关闭"
        failAll("连接已关闭")
    }
    private func receiveLoop(_ task: URLSessionWebSocketTask, current: UUID) async {
        do {
            while !Task.isCancelled {
                let incoming = try await task.receive()
                guard current == generation else { return }
                let bytes: Data
                switch incoming { case .string(let text): bytes = Data(text.utf8); case .data(let data): bytes = data; @unknown default: continue }
                guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], let type = object["type"] as? String else { continue }
                if type == "authenticated" { connected = true; connection = "远程服务已连接"; continue }
                if type == "error" { disconnected(current, reason: object["message"] as? String ?? "连接失败"); return }
                guard let id = object["id"] as? String, let continuation = pending.removeValue(forKey: id) else { continue }
                timeouts.removeValue(forKey: id)?.cancel()
                if type == "offline" { connection = "电脑端离线"; continuation.resume(throwing: BridgeError(message: "电脑端离线，请确认电脑和工作台程序正在运行。")); continue }
                guard type == "response", let code = object["status"] as? Int, let body = object["body"] as? String, let data = Data(base64Encoded: body) else { continuation.resume(throwing: BridgeError(message: "服务器响应格式错误")); continue }
                if (200..<300).contains(code) { connection = "电脑端已连接"; continuation.resume(returning: data) }
                else { let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String ?? "请求失败（\(code)）"; continuation.resume(throwing: BridgeError(message: message)) }
            }
        } catch { disconnected(current, reason: "连接已断开，正在重试") }
    }
    private func disconnected(_ current: UUID, reason: String) {
        guard current == generation else { return }
        generation = UUID(); socket?.cancel(with: .goingAway, reason: nil); socket = nil; reader = nil; connected = false; connection = reason; failAll(reason)
        reconnect?.cancel(); reconnect = Task { [weak self] in try? await Task.sleep(nanoseconds: 3_000_000_000); guard !Task.isCancelled else { return }; self?.start() }
    }
    private func failAll(_ message: String) {
        let all = pending; pending.removeAll(); timeouts.values.forEach { $0.cancel() }; timeouts.removeAll()
        for (_, continuation) in all { continuation.resume(throwing: BridgeError(message: message)) }
    }
    func request(_ path: String, body: [String: Any]? = nil, timeout: UInt64 = 35) async throws -> Data {
        guard connected, let socket else { throw BridgeError(message: "远程连接尚未就绪") }
        let id = UUID().uuidString
        let message: [String: Any] = ["type": "request", "id": id, "path": "/api/" + path, "method": body == nil ? "GET" : "POST", "body": body ?? [:]]
        let data = try JSONSerialization.data(withJSONObject: message)
        guard let text = String(data: data, encoding: .utf8) else { throw BridgeError(message: "无法编码请求") }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                guard !Task.isCancelled, let self, let item = self.pending.removeValue(forKey: id) else { return }
                self.timeouts.removeValue(forKey: id); item.resume(throwing: BridgeError(message: "请求超时，请检查电脑端连接。"))
            }
            Task { [weak self] in
                do { try await socket.send(.string(text)) }
                catch { guard let self, let item = self.pending.removeValue(forKey: id) else { return }; self.timeouts.removeValue(forKey: id)?.cancel(); item.resume(throwing: error) }
            }
        }
    }
    func decode<T: Decodable>(_ type: T.Type, _ path: String, body: [String: Any]? = nil, timeout: UInt64 = 35) async throws -> T {
        try JSONDecoder().decode(type, from: await request(path, body: body, timeout: timeout))
    }
}

