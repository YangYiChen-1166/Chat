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
                    Picker("目标人物", selection: $person) { Text("请选择").tag(""); ForEach(model.state?.facePeople ?? []) { value in Text("\(value.name) · \(value.samples) 个样本").tag(value.id) } }.accessibilityIdentifier("face-person")
                }
                Section("筛选") {
                    Text("已选择 \(model.selectedPhotos.count) 张照片").foregroundStyle(.secondary)
                    Button("开始筛选已选照片") { Task { _ = await model.command("face-scan", body: ["ids": model.selectedPhotos.map(\.id), "person": person]) } }.disabled(person.isEmpty || model.selectedPhotos.isEmpty || model.state?.busy == true).accessibilityIdentifier("start-face")
                    if let scan = model.state?.faceScan {
                        Text("已处理 \(scan.processed) / \(scan.total) · 目标 \(scan.matched) · 非目标 \(scan.unmatched) · 待复核 \(scan.review) · 失败 \(scan.failed)").font(.footnote)
                        if !scan.done { Button("停止筛选", role: .destructive) { Task { _ = await model.command("cancel") } } }
                        if scan.done { Button("将目标照片保存到电脑") { Task { _ = await model.command("face-export", body: ["run": scan.run, "allowSmall": allowSmall]) } }.disabled(scan.matched == 0) }
                    }
                }
                faceGroups
                Section {
                    Picker("传输质量", selection: $quality) { Text("快速录入").tag("fast"); Text("原尺寸").tag("original") }
                    Picker("识别模型", selection: $recognitionModel) { Text("FaceRes").tag("faceres"); Text("SFace").tag("sface") }
                    Button("发送已选照片到 LocalFace") { Task { busy = true; defer { busy = false }; if let url = await model.handoff(person: person, fast: quality == "fast", model: recognitionModel) { openURL(url) } } }.disabled(person.isEmpty || model.selectedPhotos.isEmpty || model.state?.busy == true || busy)
                } header: { Text("交给 LocalFace 录入") } footer: { Text("每次最多交接 50 张，打开 LocalFace 后继续处理。") }
            }.navigationTitle("人脸筛选").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .confirmationDialog("移除电脑端保存的 LocalFace 密钥？", isPresented: $showClear) { Button("移除", role: .destructive) { Task { _ = await model.command("face-clear") } }; Button("取消", role: .cancel) {} }
                .alert("提示", isPresented: Binding(get: { model.error != nil || model.notice != nil }, set: { if !$0 { model.error = nil; model.notice = nil } })) { Button("好", role: .cancel) { model.error = nil; model.notice = nil } } message: { Text(model.error ?? model.notice ?? "") }
                .sheet(item: $itemPreview) { item in NavigationStack { VStack { if let image = previewImage { FaceAnnotatedImage(image: image, item: item, targetID: person) } else { ProgressView() } }.frame(maxWidth: .infinity, maxHeight: .infinity).navigationTitle(item.name).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { itemPreview = nil; previewImage = nil } } } } }
        }
    }
    func groupName(_ group: String) -> String { switch group { case "target": return "目标"; case "review": return "待复核"; case "other": return "非目标"; default: return "失败" } }
    private var faceGroups: some View {
        ForEach(["target", "review", "other", "error"], id: \.self) { group in
            faceSection(group)
        }
    }
    @ViewBuilder private func faceSection(_ group: String) -> some View {
        let items = model.faceItems.values.filter { $0.group == group }.sorted { $0.name < $1.name }
        if !items.isEmpty {
            Section("\(groupName(group)) · \(items.count)") {
                ForEach(items) { item in faceRow(item) }
            }
        }
    }
    @ViewBuilder func faceRow(_ item: FaceItem) -> some View {
        HStack {
            Button { itemPreview = item; Task { await loadFace(item) } } label: {
                HStack {
                    if let raw = item.thumbnail, let data = Data(base64Encoded: raw), let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill().frame(width: 52, height: 52).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    VStack(alignment: .leading) {
                        Text(item.name)
                        if let message = item.error, !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }.buttonStyle(.plain).accessibilityLabel("预览识别结果 \(item.name)").accessibilityIdentifier("preview-face-\(item.id)")
            Spacer()
            if item.reviewable {
                Menu {
                    Button("归为目标") { Task { await model.review(item, group: "target") } }
                    Button("归为非目标") { Task { await model.review(item, group: "other") } }
                    Button("待复核") { Task { await model.review(item, group: "review") } }
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }.accessibilityLabel("复核 \(item.name)").accessibilityIdentifier("review-face-\(item.id)")
            }
        }
    }
    func loadFace(_ item: FaceItem) async {
        guard let scan = model.state?.faceScan else { return }
        struct Result: Decodable { let image: String }
        do { let value = try await model.bridge.decode(Result.self, "face-preview", body: ["run": scan.run, "id": item.id]); if let data = Data(base64Encoded: value.image) { previewImage = UIImage(data: data) } }
        catch { model.error = error.localizedDescription; itemPreview = nil }
    }
}

struct FaceAnnotatedImage: View {
    let image: UIImage
    let item: FaceItem
    let targetID: String
    var body: some View {
        GeometryReader { geometry in
            let imageWidth = CGFloat(max(item.width ?? Int(image.size.width), 1))
            let imageHeight = CGFloat(max(item.height ?? Int(image.size.height), 1))
            let scale = min(geometry.size.width / imageWidth, geometry.size.height / imageHeight)
            let drawnWidth = imageWidth * scale, drawnHeight = imageHeight * scale
            let left = (geometry.size.width - drawnWidth) / 2, top = (geometry.size.height - drawnHeight) / 2
            ZStack(alignment: .topLeading) {
                Image(uiImage: image).resizable().scaledToFit().frame(width: geometry.size.width, height: geometry.size.height)
                ForEach(Array((item.faces ?? []).enumerated()), id: \.offset) { _, face in
                    if let box = face.box, box.count == 4, box[2] > 0, box[3] > 0 {
                        let color: Color = face.person?.id == targetID ? .green : .orange
                        let width = CGFloat(box[2]) * scale, height = CGFloat(box[3]) * scale
                        Rectangle().stroke(color, lineWidth: 2).frame(width: width, height: height)
                            .overlay(alignment: .topLeading) {
                                Text(faceLabel(face)).font(.caption2).foregroundStyle(.white).padding(3).background(color)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .position(x: left + (CGFloat(box[0]) + CGFloat(box[2]) / 2) * scale, y: top + (CGFloat(box[1]) + CGFloat(box[3]) / 2) * scale)
                    }
                }
            }
        }.padding()
    }
    private func faceLabel(_ face: FaceMatch) -> String {
        let name = face.person?.name ?? "未知"
        if let score = face.similarity { return name + " · " + String(format: "%.2f", score) }
        return name
    }
}

