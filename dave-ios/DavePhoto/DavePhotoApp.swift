import SwiftUI
import UIKit

@main struct DavePhotoApp: App {
    @StateObject private var model = Workbench()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            WorkbenchRoot(model: model, bridge: model.bridge)
                .task { model.start() }
                .onChange(of: scenePhase) { phase in if phase == .active { model.start() } }
                .alert("提示", isPresented: Binding(get: { model.error != nil || model.notice != nil }, set: { if !$0 { model.error = nil; model.notice = nil } })) { Button("好", role: .cancel) { model.error = nil; model.notice = nil } } message: { Text(model.error ?? model.notice ?? "") }
        }
    }
}

struct WorkbenchRoot: View {
    @ObservedObject var model: Workbench
    @ObservedObject var bridge: PhotoBridge
    @State private var wotu = ""
    @State private var showingWotu = false
    @State private var showingMini = false
    @State private var showingFaces = false
    @State private var showingSettings = false
    @State private var showingPreview = false
    @State private var allowSmall = false
    @State private var confirmingComputerSave = false
    @State private var confirmingDeviceSave = false
    var blocked: Bool { !bridge.connected || model.state == nil || model.state?.busy == true || model.submitting }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack { Circle().fill(bridge.connection == "电脑端已连接" ? .green : .orange).frame(width: 8, height: 8); Text(bridge.connection); Spacer(); if model.state?.busy == true { ProgressView() } }
                    if let state = model.state { Text(state.status).font(.footnote).foregroundStyle(.secondary); if state.canStop { Button("停止当前任务", role: .destructive) { Task { _ = await model.command("cancel") } } } }
                } footer: { Text("读取微信相册需要电脑开机、联网，并运行大卫照片工作台。") }
                sourceSection
                if let state = model.state {
                    photoSection(state)
                    Section("保存与筛选") {
                        Toggle("允许保存小尺寸预览", isOn: $allowSmall)
                        Button { confirmingComputerSave = true } label: { Label("保存到电脑", systemImage: "desktopcomputer") }.disabled(blocked || model.selectedPhotos.isEmpty)
                        Button { confirmingDeviceSave = true } label: { Label("保存到此设备的照片", systemImage: "square.and.arrow.down") }.disabled(blocked || model.selectedPhotos.isEmpty || model.saving)
                        if model.saving { HStack { ProgressView(); Text(model.savingStatus) }.font(.footnote) }
                        if model.caching {
                            HStack { ProgressView(); Text(model.cacheStatus); Spacer(); Button("停止") { model.cancelCaching() } }.font(.footnote)
                        } else {
                            Button { model.beginCaching() } label: { Label("预加载照片到此设备", systemImage: "arrow.down.circle") }.disabled(blocked || state.photos.isEmpty)
                        }
                        Button { showingFaces = true } label: { Label("LocalFace 人脸筛选与交接", systemImage: "person.crop.rectangle.stack") }.disabled(!bridge.connected)
                    } footer: { Text("电脑端保存到：\(state.folder)\n照片可能是小尺寸或带水印的预览，不保证是原片。") }
                }
            }
            .navigationTitle("大卫照片")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button { showingSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("设置与记录") } }
            .refreshable { await model.refresh(); await model.refreshTargets() }
            .task { while !Task.isCancelled { if bridge.connected && model.targets.isEmpty { await model.refreshTargets() }; try? await Task.sleep(nanoseconds: 8_000_000_000) } }
            .alert("读取喔图相册", isPresented: $showingWotu) { TextField("相册链接", text: $wotu).textInputAutocapitalization(.never).autocorrectionDisabled(); Button("读取") { let link = wotu; Task { _ = await model.command("wotu-scan", body: ["url": link]) } }; Button("取消", role: .cancel) {} } message: { Text("请输入喔图相册链接。") }
            .confirmationDialog("将 \(model.selectedPhotos.count) 张照片保存到电脑？", isPresented: $confirmingComputerSave) { Button("保存到电脑") { Task { _ = await model.command("export", body: ["ids": model.selectedPhotos.map(\.id), "allowSmall": allowSmall, "faceFilter": false, "facePerson": ""]) } }; Button("取消", role: .cancel) {} }
            .confirmationDialog("将 \(model.selectedPhotos.count) 张照片保存到此设备？", isPresented: $confirmingDeviceSave) { Button("保存到照片") { Task { await model.saveSelectedToPhotos(allowSmall: allowSmall) } }; Button("取消", role: .cancel) {} }
            .sheet(isPresented: $showingMini) { if let id = model.selectedTarget { MiniWindow(model: model, targetID: id) } }
            .sheet(isPresented: $showingFaces) { FaceScreen(model: model, allowSmall: allowSmall) }
            .sheet(isPresented: $showingSettings) { SettingsScreen(model: model) }
        }
    }
    private var sourceSection: some View {
        Section("相册来源") {
            HStack {
                Picker("电脑窗口", selection: $model.selectedTarget) {
                    Text("请选择窗口").tag(nil as Int?)
                    ForEach(model.targets) { target in
                        Text(target.title).tag(target.id as Int?)
                    }
                }.disabled(blocked || model.targets.isEmpty)
                Button { Task { await model.refreshTargets() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(!bridge.connected).accessibilityLabel("刷新窗口")
            }
            HStack {
                Button("读取相册") { Task { await model.scan() } }.disabled(blocked || model.selectedTarget == nil)
                Spacer()
                Button("使用上次缓存") { Task { await model.scan(useCache: true) } }.disabled(blocked || model.selectedTarget == nil)
            }
            Button { showingMini = true } label: { Label("远程操作小程序", systemImage: "rectangle.on.rectangle") }.disabled(blocked || model.selectedTarget == nil)
            Button { showingWotu = true } label: { Label("读取喔图相册", systemImage: "link") }.disabled(blocked)
        }
    }
    private func photoSection(_ state: WorkState) -> some View {
        let personSelection = Binding<String>(get: { state.person ?? "" }, set: { value in Task { await model.choosePerson(value) } })
        return Section("人物与照片") {
            Picker("人物目录", selection: personSelection) {
                Text("请选择人物目录").tag("")
                ForEach(state.people) { person in
                    Text("\(person.key) · \(person.count) 张").tag(person.key)
                }
            }.disabled(blocked || state.people.isEmpty)
            Picker("照片分类", selection: $model.category) {
                ForEach(model.categories, id: \.self) { category in Text(category).tag(category) }
            }.disabled(state.photos.isEmpty)
            NavigationLink { PhotoGrid(model: model, bridge: bridge) } label: {
                HStack { Label("浏览照片", systemImage: "photo.on.rectangle.angled"); Spacer(); Text("\(model.visible.count) 张").foregroundStyle(.secondary) }
            }.disabled(state.photos.isEmpty)
            HStack {
                Text("已选 \(model.selectedPhotos.count) 张"); Spacer()
                Button("全选当前分类") { model.selected.formUnion(model.visible.map(\.id)) }.disabled(blocked || model.visible.isEmpty)
                Button("清除") { model.selected.removeAll() }.disabled(model.selected.isEmpty)
            }.font(.subheadline)
        }
    }
}

struct PhotoGrid: View {
    @ObservedObject var model: Workbench
    @ObservedObject var bridge: PhotoBridge
    @State private var preview: PhotoItem?
    private let columns = [GridItem(.adaptive(minimum: 130), spacing: 10)]
    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(model.visible) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        ZStack(alignment: .topTrailing) {
                            Button { preview = item; Task { await model.showPreview(item) } } label: {
                                Group { if let image = model.thumbnails[item.id] { Image(uiImage: image).resizable().scaledToFill() } else { Rectangle().fill(Color(.secondarySystemBackground)).overlay { Image(systemName: "photo").foregroundStyle(.secondary) } } }
                                    .frame(height: 130).frame(maxWidth: .infinity).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain)
                            Button { if model.selected.contains(item.id) { model.selected.remove(item.id) } else { model.selected.insert(item.id) } } label: { Image(systemName: model.selected.contains(item.id) ? "checkmark.circle.fill" : "circle").font(.title2).foregroundStyle(model.selected.contains(item.id) ? Color.accentColor : .white).shadow(radius: 2) }.padding(8).accessibilityLabel(model.selected.contains(item.id) ? "取消选择 \(item.name)" : "选择 \(item.name)")
                        }
                        Text(item.name).font(.caption).lineLimit(2)
                    }.task { model.loadThumbnail(item) }
                }
            }.padding()
        }
        .navigationTitle(model.category).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Menu { Button("全选当前分类") { model.selected.formUnion(model.visible.map(\.id)) }; Button("取消当前分类选择") { model.selected.subtract(model.visible.map(\.id)) } } label: { Text("已选 \(model.selectedPhotos.count)") } } }
        .sheet(item: $preview) { item in NavigationStack { VStack { if let image = model.previewImage, model.previewName == item.name { Image(uiImage: image).resizable().scaledToFit() } else { ProgressView("正在读取预览…") } }.frame(maxWidth: .infinity, maxHeight: .infinity).navigationTitle(item.name).navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { preview = nil } } } } }
    }
}

struct SettingsScreen: View {
    @ObservedObject var model: Workbench
    @Environment(\.dismiss) private var dismiss
    @State private var folder = ""
    @State private var editFolder = false
    var body: some View {
        NavigationStack {
            List {
                Section("电脑端保存位置") { Text(model.state?.folder ?? "未连接").textSelection(.enabled); Button("修改电脑端文件夹") { folder = model.state?.folder ?? ""; editFolder = true } }
                Section("设备预览缓存") { Text("已使用 \(model.cacheSize / 1024 / 1024) MB，上限 128 MB"); Button("清理设备缓存", role: .destructive) { model.clearCache() }.disabled(model.caching) }
                Section("任务记录") { if let log = model.state?.log, !log.isEmpty { ForEach(Array(log.enumerated()), id: \.offset) { _, line in Text(line).font(.footnote).textSelection(.enabled) } } else { Text("暂无记录").foregroundStyle(.secondary) } }
                Section("连接说明") { Text("应用使用现有的大卫照片远程连接。电脑端需要保持运行，当前远程入口按现有配置开放访问。") }
            }.navigationTitle("设置").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .alert("修改电脑端文件夹", isPresented: $editFolder) { TextField("电脑上的绝对路径", text: $folder); Button("保存") { let value = folder; Task { _ = await model.command("set-folder", body: ["folder": value]) } }; Button("取消", role: .cancel) {} } message: { Text("请输入电脑上已经存在的本地文件夹路径。") }
        }
    }
}

