import SwiftUI
import Photos
import UIKit
import ImageIO

struct ShareBundle: Identifiable { let id = UUID(); let directory: URL; let files: [URL] }

@MainActor final class Workbench: ObservableObject {
    let bridge = PhotoBridge()
    @Published var state: WorkState?
    @Published var targets: [PhotoTarget] = []
    @Published var selectedTarget: Int?
    @Published var category = "全部分类"
    @Published var selected: Set<Int> = []
    @Published var error: String?
    @Published var notice: String?
    @Published var submitting = false
    @Published var previewImage: UIImage?
    @Published var previewName = ""
    @Published var thumbnails: [Int: UIImage] = [:]
    @Published var faceItems: [Int: FaceItem] = [:]
    @Published var saving = false
    @Published var savingStatus = ""
    @Published var shareBundle: ShareBundle?
    @Published var caching = false
    @Published var cacheStatus = ""
    @Published var cacheSize = 0
    private let cache = PreviewCache()
    private var cacheTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var refreshInFlight = false
    private var thumbQueue: [Int] = []
    private var thumbActive = false
    private var thumbGeneration = -1
    private var thumbPerson: String?
    private var faceRun = ""
    private var faceCursor = 0
    private var facePolling = false
    private var lastPreviewRevision = ""
    var visible: [PhotoItem] { (state?.photos ?? []).filter { category == "全部分类" || $0.album == category } }
    var categories: [String] { ["全部分类"] + Array(Set((state?.photos ?? []).map(\.album))).sorted() }
    var selectedPhotos: [PhotoItem] { (state?.photos ?? []).filter { selected.contains($0.id) } }

    func start() {
        cacheSize = cache.used()
        bridge.start()
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.bridge.connected { await self.refresh(silent: true) }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
        }
    }
    func stop() { pollTask?.cancel(); pollTask = nil; bridge.stop() }
    func refresh(silent: Bool = false) async {
        guard !refreshInFlight else { return }; refreshInFlight = true; defer { refreshInFlight = false }
        do {
            let value = try await bridge.decode(WorkState.self, "state")
            if thumbGeneration != value.libraryGeneration || thumbPerson != value.person {
                thumbnails.removeAll(); thumbQueue.removeAll(); selected.removeAll(); category = "全部分类"
                thumbGeneration = value.libraryGeneration; thumbPerson = value.person
            }
            state = value
            if selectedTarget == nil, let target = value.targetId { selectedTarget = target }
            if !categories.contains(category) { category = "全部分类" }
            selected = selected.intersection(Set(value.photos.map(\.id)))
            if let info = value.preview, info.revision != lastPreviewRevision {
                lastPreviewRevision = info.revision
            }
            if let scan = value.faceScan {
                if faceRun != scan.run { faceRun = scan.run; faceCursor = 0; faceItems.removeAll() }
                await refreshFaceResults()
            } else if !faceRun.isEmpty { faceRun = ""; faceCursor = 0; faceItems.removeAll() }
        } catch { if !silent { self.error = error.localizedDescription } }
    }
    func refreshTargets() async {
        do { targets = try await bridge.decode([PhotoTarget].self, "targets"); if !targets.contains(where: { $0.id == selectedTarget }) { selectedTarget = targets.first?.id }; if targets.isEmpty { notice = "电脑上没有找到大卫小程序窗口。" } }
        catch { self.error = error.localizedDescription }
    }
    @discardableResult func command(_ name: String, body: [String: Any] = [:]) async -> Bool {
        guard !submitting else { return false }; submitting = true; defer { submitting = false }
        do { _ = try await bridge.request(name, body: body); await refresh(); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func scan(useCache: Bool = false) async {
        guard let id = selectedTarget else { error = "请先刷新并选择电脑上的小程序窗口。"; return }
        if await command("scan", body: ["id": id, "useCache": useCache]) { selected.removeAll() }
    }
    func choosePerson(_ person: String) async { if await command("person", body: ["person": person]) { selected.removeAll(); category = "全部分类" } }
    func showPreview(_ item: PhotoItem) async {
        if let cached = cache.read(item.cacheKey), let image = UIImage(data: cached) {
            previewImage = image; previewName = item.name; return
        }
        if let image = thumbnails[item.id] { previewImage = image; previewName = item.name }
        guard await command("preview", body: ["id": item.id]) else { return }
        let baseline = state?.preview?.revision
        for _ in 0..<45 {
            await refresh(silent: true)
            if let info = state?.preview, (!state!.busy || info.revision != baseline) {
                do { let data = try await bridge.request("image"); guard let image = UIImage(data: data) else { throw BridgeError(message: "图片格式无法预览") }; previewImage = image; previewName = info.name }
                catch { self.error = error.localizedDescription }
                return
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        error = "预览超时，请稍后重试。"
    }
    func loadThumbnail(_ item: PhotoItem) {
        guard thumbnails[item.id] == nil, !thumbQueue.contains(item.id) else { return }
        if let data = cache.read(item.cacheKey), let image = makeThumbnail(data) { thumbnails[item.id] = image; return }
        thumbQueue.append(item.id)
        guard !thumbActive else { return }
        thumbActive = true
        Task { [weak self] in await self?.drainThumbnails() }
    }
    private func drainThumbnails() async {
        defer { thumbActive = false }
        while !thumbQueue.isEmpty && bridge.connected {
            let batch = Array(thumbQueue.prefix(3)); thumbQueue.removeFirst(min(3, thumbQueue.count))
            let generation = thumbGeneration, person = thumbPerson
            do {
                let page = try await bridge.decode(ThumbPage.self, "face-thumbnails", body: ["ids": batch])
                guard generation == thumbGeneration, person == thumbPerson else { continue }
                for item in page.items { if let raw = item.thumbnail, let data = Data(base64Encoded: raw), let image = UIImage(data: data) { thumbnails[item.id] = image } }
            } catch { if !bridge.connected { break } }
        }
    }
    private func makeThumbnail(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 320]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
    func refreshFaceResults() async {
        guard !faceRun.isEmpty, !facePolling else { return }; facePolling = true; defer { facePolling = false }
        do { let result = try await bridge.decode(FaceResultPage.self, "face-results", body: ["run": faceRun, "cursor": faceCursor]); for item in result.items { faceItems[item.id] = item }; faceCursor = result.next }
        catch { }
    }
    func review(_ item: FaceItem, group: String) async { guard let scan = state?.faceScan else { return }; _ = await command("face-review", body: ["run": scan.run, "id": item.id, "group": group]); await refreshFaceResults() }
    func clearCache() {
        guard !caching else { error = "请先停止预加载。"; return }
        do { try cache.clear(); cacheSize = 0; thumbnails.removeAll(); notice = "设备预览缓存已清理。" }
        catch { self.error = error.localizedDescription }
    }
    func beginCaching() {
        guard !caching, let current = state, !current.photos.isEmpty else { return }
        let photos = current.photos, generation = current.libraryGeneration, person = current.person
        caching = true
        cacheTask = Task { [weak self] in
            guard let self else { return }
            defer { self.caching = false; self.cacheStatus = ""; self.cacheTask = nil; self.cacheSize = self.cache.used() }
            do {
                let missing = photos.filter { self.cache.read($0.cacheKey) == nil }
                if missing.isEmpty { self.notice = "当前照片的预览已在设备缓存中。"; return }
                self.cacheStatus = "电脑正在准备 \(missing.count) 张预览"
                guard await self.command("preload-previews", body: ["ids": missing.map(\.id)]) else { return }
                var prepared = false
                for _ in 0..<600 {
                    try Task.checkCancellation()
                    await self.refresh(silent: true)
                    guard self.state?.libraryGeneration == generation, self.state?.person == person else { throw BridgeError(message: "相册已变化，请重新加载。") }
                    if let progress = self.state?.preload, !progress.active, self.state?.busy == false, progress.total > 0 { prepared = true; break }
                    if let progress = self.state?.preload { self.cacheStatus = "电脑准备预览 \(progress.done) / \(progress.total)" }
                    try await Task.sleep(nanoseconds: 800_000_000)
                }
                guard prepared else { throw BridgeError(message: "电脑准备预览超时。") }
                var completed = 0, failed = 0
                for start in stride(from: 0, to: missing.count, by: 3) {
                    try Task.checkCancellation()
                    guard self.state?.libraryGeneration == generation, self.state?.person == person else { throw BridgeError(message: "相册已变化，请重新加载。") }
                    let batch = Array(missing[start..<min(start + 3, missing.count)])
                    let results = await withTaskGroup(of: (PhotoItem, Data?).self, returning: [(PhotoItem, Data?)].self) { group in
                        for item in batch { group.addTask { let bytes = try? await self.bridge.request("cached-preview", body: ["id": item.id, "generation": generation]); return (item, bytes) } }
                        var results: [(PhotoItem, Data?)] = []; for await value in group { results.append(value) }; return results
                    }
                    for (item, data) in results {
                        if let data, let image = self.makeThumbnail(data) { try self.cache.write(data, key: item.cacheKey); self.thumbnails[item.id] = image; completed += 1 }
                        else { failed += 1 }
                    }
                    self.cacheStatus = "传输到设备 \(completed + failed) / \(missing.count)"
                }
                self.notice = "预览缓存完成：成功 \(completed) 张，失败 \(failed) 张。"
            } catch is CancellationError { self.notice = "已停止预加载。" }
            catch { self.error = error.localizedDescription }
        }
    }
    func cancelCaching() {
        cacheTask?.cancel()
        if state?.preload?.active == true { Task { _ = await command("cancel") } }
    }
    func handoff(person: String, fast: Bool, model: String) async -> URL? {
        guard !selectedPhotos.isEmpty, selectedPhotos.count <= 50 else { error = "请选择 1 到 50 张照片。"; return nil }
        do {
            let result = try await bridge.decode(Handoff.self, "handoff-create", body: ["person": person, "ids": selectedPhotos.map(\.id), "fast": fast])
            var parts = URLComponents(string: "https://local-face.yyc1166.ccwu.cc/admin/training")!
            parts.queryItems = [URLQueryItem(name: "person", value: person), URLQueryItem(name: "dave_transfer", value: result.token), URLQueryItem(name: "dave_model", value: model)]
            return parts.url
        } catch { self.error = error.localizedDescription; return nil }
    }
    func saveSelectedToPhotos(allowSmall: Bool) async {
        guard !saving, let generation = state?.libraryGeneration else { return }
        let items = selectedPhotos; guard !items.isEmpty else { error = "请先选择照片。"; return }
        let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard permission == .authorized || permission == .limited else { error = "请在系统设置中允许添加照片。"; return }
        saving = true; defer { saving = false }; var ok = 0; var failed: [String] = []
        for (index, item) in items.enumerated() {
            savingStatus = "正在保存 \(index + 1) / \(items.count)"
            do {
                let (data, ext) = try await fetchOriginal(item, generation: generation, allowSmall: allowSmall)
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                try data.write(to: file, options: .atomic)
                defer { try? FileManager.default.removeItem(at: file) }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    PHPhotoLibrary.shared().performChanges({ PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: nil) }) { success, failure in
                        if success { continuation.resume() } else { continuation.resume(throwing: failure ?? BridgeError(message: "照片图库保存失败")) }
                    }
                }
                ok += 1
            } catch { failed.append(item.name + "：" + error.localizedDescription) }
        }
        savingStatus = ""
        notice = "已保存 \(ok) / \(items.count) 张。" + (failed.isEmpty ? "" : "\n" + failed.prefix(5).joined(separator: "\n"))
    }
    private func fetchOriginal(_ item: PhotoItem, generation: Int, allowSmall: Bool) async throws -> (Data, String) {
        var data = Data(), total: Int?, ext = "jpg"
        repeat {
            guard state?.libraryGeneration == generation else { throw BridgeError(message: "相册已变化") }
            let part = try await bridge.decode(OriginalChunk.self, "device-original", body: ["id": item.id, "generation": generation, "offset": data.count, "allowSmall": allowSmall], timeout: 120)
            guard part.total > 0, part.total <= 40 * 1024 * 1024, total == nil || total == part.total, let chunk = Data(base64Encoded: part.data), !chunk.isEmpty, data.count + chunk.count <= part.total else { throw BridgeError(message: "图片传输不完整") }
            total = part.total; ext = part.extension.trimmingCharacters(in: CharacterSet(charactersIn: ".")); data.append(chunk)
        } while data.count < (total ?? 0)
        guard ["jpg", "png", "webp", "bmp"].contains(ext) else { throw BridgeError(message: "图片格式不受支持") }
        return (data, ext)
    }
    func prepareShare(allowSmall: Bool) async {
        guard !saving, let generation = state?.libraryGeneration else { return }
        let items = selectedPhotos; guard !items.isEmpty else { error = "请先选择照片。"; return }
        saving = true; defer { saving = false; savingStatus = "" }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DaveShare-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var files: [URL] = [], totalBytes = 0
            for (index, item) in items.enumerated() {
                savingStatus = "正在准备 \(index + 1) / \(items.count)"
                let (data, ext) = try await fetchOriginal(item, generation: generation, allowSmall: allowSmall)
                totalBytes += data.count
                guard totalBytes <= 128 * 1024 * 1024 else { throw BridgeError(message: "本次分享超过 128 MB，请分批选择。") }
                let file = folder.appendingPathComponent("照片-\(index + 1)").appendingPathExtension(ext)
                try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]); files.append(file)
            }
            shareBundle = ShareBundle(directory: folder, files: files)
        } catch { try? FileManager.default.removeItem(at: folder); self.error = error.localizedDescription }
    }
    func removeShareFiles(_ bundle: ShareBundle) { try? FileManager.default.removeItem(at: bundle.directory) }
}

