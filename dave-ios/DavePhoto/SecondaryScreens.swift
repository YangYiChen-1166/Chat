import SwiftUI
import UIKit

struct MiniWindow: View {
    @ObservedObject var model: Workbench
    let targetID: Int
    @Environment(\.dismiss) private var dismiss
    @State private var frame: UIImage?
    @State private var loading = false
    @State private var status = "正在读取窗口画面…"
    @State private var acting = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    ZStack {
                        Color(.secondarySystemBackground)
                        if let frame {
                            Image(uiImage: frame).resizable().scaledToFit()
                                .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                                    let scale = min(geometry.size.width / frame.size.width, geometry.size.height / frame.size.height)
                                    let width = frame.size.width * scale, height = frame.size.height * scale
                                    let left = (geometry.size.width - width) / 2, top = (geometry.size.height - height) / 2
                                    let x = max(0, min(1, (value.location.x - left) / width)), y = max(0, min(1, (value.location.y - top) / height))
                                    let dy = value.translation.height
                                    Task { await action(abs(dy) > 20 ? "scroll" : "tap", x: x, y: y, delta: abs(dy) > 20 ? (dy > 0 ? 120 : -120) : 0) }
                                })
                        } else { ProgressView() }
                    }
                }
                Text(status).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding()
                HStack {
                    Button("向上") { Task { await action("scroll", x: 0.5, y: 0.55, delta: 120) } }
                    Button("向下") { Task { await action("scroll", x: 0.5, y: 0.55, delta: -120) } }
                    Spacer()
                    Button("读取相册") { dismiss(); Task { await model.scan() } }.buttonStyle(.borderedProminent).disabled(model.state?.busy == true)
                }.buttonStyle(.bordered).padding()
            }.navigationTitle("远程选择人物").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .task { while !Task.isCancelled { await refreshFrame(); try? await Task.sleep(nanoseconds: 67_000_000) } }
        }
    }
    func refreshFrame() async {
        guard !loading else { return }; loading = true; defer { loading = false }
        do { let data = try await model.bridge.request("mini-frame", body: ["id": targetID]); if let image = UIImage(data: data) { frame = image; status = "点击画面操作；滑动或使用按钮滚动。" } }
        catch { status = "画面读取失败：" + error.localizedDescription; try? await Task.sleep(nanoseconds: 2_000_000_000) }
    }
    func action(_ kind: String, x: CGFloat, y: CGFloat, delta: Int) async {
        guard !acting, let frame else { return }; acting = true; defer { acting = false }
        do { _ = try await model.bridge.request("mini-action", body: ["id": targetID, "kind": kind, "x": Double(x), "y": Double(y), "delta": delta, "width": Int(frame.size.width * frame.scale), "height": Int(frame.size.height * frame.scale)]); status = "操作已发送" }
        catch { status = error.localizedDescription }
    }
}

struct FaceScreen: View {
    @ObservedObject var model: Workbench
    let allowSmall: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var faceKey = ""
    @State private var person = ""
    @State private var quality = "fast"
    @State private var recognitionModel = "faceres"
    @State private var showClear = false
    @State private var itemPreview: FaceItem?
    @State private var previewImage: UIImage?
    @State private var busy = false
    var body: some View {
        NavigationStack {
            List {
                Section("LocalFace 连接") {
                    Text(model.state?.faceConfigured == true ? "已连接" : "未连接").foregroundStyle(.secondary)
                    SecureField("LocalFace API 密钥", text: $faceKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack {
                        Button("连接") { let key = faceKey; faceKey = ""; Task { _ = await model.command("face-connect", body: ["key": key]) } }.disabled(faceKey.isEmpty || model.state?.busy == true)
                        Spacer()
                        Button("刷新人物") { Task { _ = await model.command("face-refresh") } }.disabled(model.state?.faceConfigured != true || model.state?.busy == true)
                        Button("移除密钥", role: .destructive) { showClear = true }.disabled(model.state?.faceConfigured != true)
                    }
                    Picker("目标人物", selection: $person) { Text("请选择").tag(""); ForEach(model.state?.facePeople ?? []) { value in Text("\(value.name) · \(value.samples) 个样本").tag(value.id) } }
                }
                Section("筛选") {
                    Text("已选择 \(model.selectedPhotos.count) 张照片").foregroundStyle(.secondary)
                    Button("开始筛选已选照片") { Task { _ = await model.command("face-scan", body: ["ids": model.selectedPhotos.map(\.id), "person": person]) } }.disabled(person.isEmpty || model.selectedPhotos.isEmpty || model.state?.busy == true)
                    if let scan = model.state?.faceScan {
                        Text("已处理 \(scan.processed) / \(scan.total) · 目标 \(scan.matched) · 非目标 \(scan.unmatched) · 待复核 \(scan.review) · 失败 \(scan.failed)").font(.footnote)
                        if !scan.done { Button("停止筛选", role: .destructive) { Task { _ = await model.command("cancel") } } }
                        if scan.done { Button("将目标照片保存到电脑") { Task { _ = await model.command("face-export", body: ["run": scan.run, "allowSmall": allowSmall]) } }.disabled(scan.matched == 0) }
                    }
                }
                if !model.faceItems.isEmpty {
                    ForEach(["target", "review", "other", "error"], id: \.self) { group in
                        let items = model.faceItems.values.filter { $0.group == group }.sorted { $0.name < $1.name }
                        if !items.isEmpty {
                            Section(groupName(group) + " · \(items.count)") {
                                ForEach(items) { item in
                                    HStack {
                                        Button { itemPreview = item; Task { await loadFace(item) } } label: {
                                            HStack { if let raw = item.thumbnail, let data = Data(base64Encoded: raw), let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill().frame(width: 52, height: 52).clipped().clipShape(RoundedRectangle(cornerRadius: 6)) }; VStack(alignment: .leading) { Text(item.name); if let error = item.error, !error.isEmpty { Text(error).font(.caption).foregroundStyle(.secondary) } } }
                                        }.buttonStyle(.plain)
                                        Spacer()
                                        if item.reviewable { Menu { Button("归为目标") { Task { await model.review(item, group: "target") } }; Button("归为非目标") { Task { await model.review(item, group: "other") } }; Button("待复核") { Task { await model.review(item, group: "review") } } } label: { Image(systemName: "ellipsis.circle").font(.title3) } }
                                    }
                                }
                            }
                        }
                    }
                }
                Section("交给 LocalFace 录入") {
                    Picker("传输质量", selection: $quality) { Text("快速录入").tag("fast"); Text("原尺寸").tag("original") }
                    Picker("识别模型", selection: $recognitionModel) { Text("FaceRes").tag("faceres"); Text("SFace").tag("sface") }
                    Button("发送已选照片到 LocalFace") { Task { busy = true; defer { busy = false }; if let url = await model.handoff(person: person, fast: quality == "fast", model: recognitionModel) { openURL(url) } } }.disabled(person.isEmpty || model.selectedPhotos.isEmpty || model.state?.busy == true || busy)
                } footer: { Text("每次最多交接 50 张，打开 LocalFace 后继续处理。") }
            }.navigationTitle("人脸筛选").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .confirmationDialog("移除电脑端保存的 LocalFace 密钥？", isPresented: $showClear) { Button("移除", role: .destructive) { Task { _ = await model.command("face-clear") } }; Button("取消", role: .cancel) {} }
                .sheet(item: $itemPreview) { item in NavigationStack { VStack { if let image = previewImage { Image(uiImage: image).resizable().scaledToFit() } else { ProgressView() } }.frame(maxWidth: .infinity, maxHeight: .infinity).navigationTitle(item.name).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { itemPreview = nil; previewImage = nil } } } } }
        }
    }
    func groupName(_ group: String) -> String { switch group { case "target": return "目标"; case "review": return "待复核"; case "other": return "非目标"; default: return "失败" } }
    func loadFace(_ item: FaceItem) async {
        guard let scan = model.state?.faceScan else { return }
        struct Result: Decodable { let image: String }
        do { let value = try await model.bridge.decode(Result.self, "face-preview", body: ["run": scan.run, "id": item.id]); if let data = Data(base64Encoded: value.image) { previewImage = UIImage(data: data) } }
        catch { model.error = error.localizedDescription; itemPreview = nil }
    }
}

