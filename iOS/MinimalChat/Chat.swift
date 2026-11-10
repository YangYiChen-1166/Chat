import SwiftUI
import PhotosUI
import AVFoundation
import Security
import UIKit

struct Person: Codable, Identifiable, Hashable { let id: String; let username: String }
struct Session: Decodable { let token: String; let user: Person }
struct FriendList: Decodable { let friends: [Person]; let requests: [Person] }
struct MessageList: Decodable { let messages: [Message] }
struct Message: Decodable, Identifiable { let id: String; let sender_id: String; let recipient_id: String; let kind: String; let body: String?; let created_at: Double }
struct ServerError: Decodable { let error: String }
struct APIError: LocalizedError { let message: String; var errorDescription: String? { message } }

enum Keychain {
    static let service = "com.minimalchat.session"
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "token"] }
    static func save(_ token: String) { SecItemDelete(query as CFDictionary); var item = query; item[kSecValueData as String] = Data(token.utf8); item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly; SecItemAdd(item as CFDictionary, nil) }
    static func load() -> String? { var q = query; q[kSecReturnData as String] = true; var value: CFTypeRef?; guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }; return String(data: data, encoding: .utf8) }
    static func clear() { SecItemDelete(query as CFDictionary) }
}

final class API {
    static let base = URL(string: "https://minimal-chat-api.yangyichen1166.workers.dev")!
    var token: String?
    func request(_ path: String, method: String = "GET", json: [String: String]? = nil, data: Data? = nil, type: String? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: Self.base) else { throw APIError(message: "地址无效") }
        var req = URLRequest(url: url); req.httpMethod = method; req.timeoutInterval = 45
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json { req.httpBody = try JSONSerialization.data(withJSONObject: json); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let data { req.httpBody = data; req.setValue(type, forHTTPHeaderField: "Content-Type") }
        let (result, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError(message: "服务器响应无效") }
        guard (200..<300).contains(http.statusCode) else { throw APIError(message: (try? JSONDecoder().decode(ServerError.self, from: result).error) ?? "请求失败（\(http.statusCode)）") }
        return result
    }
    func decode<T: Decodable>(_ type: T.Type, _ path: String, method: String = "GET", json: [String: String]? = nil) async throws -> T { try JSONDecoder().decode(type, from: await request(path, method: method, json: json)) }
}

@MainActor final class AppModel: ObservableObject {
    @Published var me: Person?
    @Published var friends: [Person] = []
    @Published var requests: [Person] = []
    @Published var error: String?
    @Published var busy = false
    @Published var restoring = true
    let api = API()
    func restore() async {
        defer { restoring = false }; guard let token = Keychain.load() else { return }; api.token = token
        do { me = try await api.decode(Person.self, "/me"); await refresh() }
        catch { api.token = nil; Keychain.clear(); self.error = "登录已失效或网络不可用，请重新登录。" }
    }
    func authenticate(username: String, password: String, register: Bool) async {
        busy = true; defer { busy = false }
        do { let session = try await api.decode(Session.self, register ? "/register" : "/login", method: "POST", json: ["username": username.trimmingCharacters(in: .whitespacesAndNewlines), "password": password]); api.token = session.token; Keychain.save(session.token); me = session.user; await refresh() }
        catch { self.error = error.localizedDescription }
    }
    func refresh() async { guard me != nil else { return }; do { let list = try await api.decode(FriendList.self, "/friends"); friends = list.friends; requests = list.requests } catch { self.error = error.localizedDescription } }
    func sendRequest(_ username: String) async { do { _ = try await api.request("/friends/request", method: "POST", json: ["username": username.trimmingCharacters(in: .whitespacesAndNewlines)]); await refresh() } catch { self.error = error.localizedDescription } }
    func accept(_ person: Person) async { do { _ = try await api.request("/friends/\(person.id)/accept", method: "POST", json: [:]); await refresh() } catch { self.error = error.localizedDescription } }
    func logout() async { _ = try? await api.request("/logout", method: "POST", json: [:]); api.token = nil; Keychain.clear(); me = nil; friends = []; requests = [] }
}

struct LoginView: View {
    @EnvironmentObject var model: AppModel
    @State private var username = ""
    @State private var password = ""
    @State private var register = false
    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("用户名", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username); SecureField("密码", text: $password).textContentType(register ? .newPassword : .password) }
                footer: { if register { Text("用户名为 3–24 位字母、数字或下划线，密码至少 10 位。请记住密码，当前版本暂不支持找回。") } }
                Section { Button(register ? "创建账号" : "登录") { Task { await model.authenticate(username: username, password: password, register: register) } }.disabled(username.isEmpty || password.isEmpty || model.busy); Button(register ? "已有账号？登录" : "没有账号？注册") { register.toggle() } }
            }.navigationTitle(register ? "创建账号" : "登录")
        }
    }
}

struct FriendsView: View {
    @EnvironmentObject var model: AppModel
    @State private var showingAdd = false
    @State private var username = ""
    var body: some View {
        NavigationStack {
            List {
                if !model.requests.isEmpty { Section("好友申请") { ForEach(model.requests) { person in HStack { Label(person.username, systemImage: "person.crop.circle"); Spacer(); Button("接受") { Task { await model.accept(person) } }.buttonStyle(.bordered) } } } }
                Section("好友") { if model.friends.isEmpty { Text("添加好友后开始聊天").foregroundStyle(.secondary) }; ForEach(model.friends) { person in NavigationLink(value: person) { Label(person.username, systemImage: "person.crop.circle.fill") } } }
            }.navigationTitle("聊天").navigationDestination(for: Person.self) { ChatView(person: $0) }
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) { Menu { Text("当前账号：\(model.me?.username ?? "")"); Button("退出登录", role: .destructive) { Task { await model.logout() } } } label: { Image(systemName: "person.crop.circle") } }
                    ToolbarItem(placement: .navigationBarTrailing) { Button { showingAdd = true } label: { Image(systemName: "person.badge.plus") }.accessibilityLabel("添加好友") }
                }
                .refreshable { await model.refresh() }
                .task { while !Task.isCancelled { try? await Task.sleep(nanoseconds: 15_000_000_000); if !Task.isCancelled { await model.refresh() } } }
                .alert("添加好友", isPresented: $showingAdd) { TextField("好友用户名", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled(); Button("发送申请") { let name = username; username = ""; Task { await model.sendRequest(name) } }; Button("取消", role: .cancel) { username = "" } } message: { Text("输入对方注册时使用的用户名。") }
        }
    }
}

@MainActor final class AudioController: NSObject, ObservableObject {
    @Published var recording = false
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var url: URL?
    func start() async throws {
        let granted = await withCheckedContinuation { continuation in AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) } }
        guard granted else { throw APIError(message: "请在系统设置中允许使用麦克风。") }
        let session = AVAudioSession.sharedInstance(); try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker]); try session.setActive(true)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 22050, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
        let recorder = try AVAudioRecorder(url: file, settings: settings); guard recorder.record(forDuration: 60) else { throw APIError(message: "无法开始录音") }; self.recorder = recorder; url = file; recording = true
    }
    func stop() throws -> Data { recorder?.stop(); recorder = nil; recording = false; guard let url else { throw APIError(message: "没有录音") }; defer { try? FileManager.default.removeItem(at: url); self.url = nil }; return try Data(contentsOf: url) }
    func cancel() { recorder?.stop(); recorder = nil; recording = false; if let url { try? FileManager.default.removeItem(at: url) }; url = nil }
    func play(_ data: Data) throws { try AVAudioSession.sharedInstance().setCategory(.playback); try AVAudioSession.sharedInstance().setActive(true); player = try AVAudioPlayer(data: data); player?.play() }
}

struct ChatView: View {
    let person: Person
    @EnvironmentObject var model: AppModel
    @StateObject private var audio = AudioController()
    @State private var messages: [Message] = []
    @State private var text = ""
    @State private var selected: PhotosPickerItem?
    @State private var sending = false
    @State private var loading = true
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { LazyVStack(spacing: 12) { if loading { ProgressView().padding() } else if messages.isEmpty { Text("发送第一条消息").foregroundStyle(.secondary).padding() }; ForEach(messages) { message in MessageRow(message: message, own: message.sender_id == model.me?.id, api: model.api, audio: audio).id(message.id) } }.padding() }
                .onChange(of: messages.count) { _ in if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
                .safeAreaInset(edge: .bottom) { composer }
                .navigationTitle(person.username).navigationBarTitleDisplayMode(.inline)
                .task { await refresh(); while !Task.isCancelled { try? await Task.sleep(nanoseconds: 3_000_000_000); if !Task.isCancelled { await refresh(silent: true) } } }
                .onDisappear { audio.cancel() }
                .onChange(of: selected) { item in guard let item else { return }; Task { await sendPhoto(item); selected = nil } }
        }
    }
    var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            PhotosPicker(selection: $selected, matching: .images) { Image(systemName: "photo") }.disabled(sending || audio.recording).accessibilityLabel("选择图片")
            Button { Task { await toggleRecording() } } label: { Image(systemName: audio.recording ? "stop.circle.fill" : "mic") }.disabled(sending).accessibilityLabel(audio.recording ? "停止录音并发送" : "录制语音")
            if audio.recording { Text("录音中，点停止发送").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
            else { TextField("消息", text: $text, axis: .vertical).lineLimit(1...4).textFieldStyle(.roundedBorder); Button { Task { await sendText() } } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }.disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("发送") }
        }.padding(.horizontal).padding(.vertical, 10).background(.bar)
    }
    func refresh(silent: Bool = false) async { do { let result = try await model.api.decode(MessageList.self, "/messages/\(person.id)"); messages = result.messages; loading = false } catch { loading = false; if !silent { model.error = error.localizedDescription } } }
    func sendText() async { let value = text.trimmingCharacters(in: .whitespacesAndNewlines); guard !value.isEmpty else { return }; sending = true; defer { sending = false }; do { _ = try await model.api.request("/messages/\(person.id)", method: "POST", json: ["text": value]); text = ""; await refresh() } catch { model.error = error.localizedDescription } }
    func sendPhoto(_ item: PhotosPickerItem) async {
        sending = true; defer { sending = false }
        do { guard let raw = try await item.loadTransferable(type: Data.self), let image = UIImage(data: raw), let data = image.jpegData(compressionQuality: 0.75) else { throw APIError(message: "无法读取图片") }; guard data.count <= 10 * 1024 * 1024 else { throw APIError(message: "图片不能超过 10 MB") }; _ = try await model.api.request("/media/\(person.id)/image", method: "POST", data: data, type: "image/jpeg"); await refresh() } catch { model.error = error.localizedDescription }
    }
    func toggleRecording() async {
        do { if audio.recording { let data = try audio.stop(); sending = true; defer { sending = false }; _ = try await model.api.request("/media/\(person.id)/audio", method: "POST", data: data, type: "audio/mp4"); await refresh() } else { try await audio.start() } } catch { model.error = error.localizedDescription }
    }
}

struct MessageRow: View {
    let message: Message
    let own: Bool
    let api: API
    @ObservedObject var audio: AudioController
    @State private var image: UIImage?
    @State private var mediaError = false
    var body: some View {
        HStack(alignment: .bottom) {
            if own { Spacer(minLength: 40) }
            VStack(alignment: own ? .trailing : .leading, spacing: 4) {
                Group {
                    if message.kind == "text" { Text(message.body ?? "") }
                    else if message.kind == "image" { Group { if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 220, maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 12)) } else if mediaError { Text("图片加载失败") } else { ProgressView().frame(width: 100, height: 80) } }.task { do { let data = try await api.request("/media/\(message.id)"); image = UIImage(data: data); mediaError = image == nil } catch { mediaError = true } } }
                    else { Button { Task { do { let data = try await api.request("/media/\(message.id)"); try audio.play(data) } catch { mediaError = true } } } label: { Label(mediaError ? "播放失败" : "播放语音", systemImage: "play.fill") } }
                }.padding(10).background(own ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                Text(Date(timeIntervalSince1970: message.created_at / 1000), style: .time).font(.caption2).foregroundStyle(.secondary)
            }
            if !own { Spacer(minLength: 40) }
        }
    }
}


