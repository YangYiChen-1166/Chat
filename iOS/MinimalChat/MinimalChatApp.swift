import SwiftUI
@main struct MinimalChatApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            Group { if model.restoring { ProgressView() } else if model.me == nil { LoginView() } else { FriendsView() } }
                .environmentObject(model).task { await model.restore() }
                .alert("提示", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("好", role: .cancel) { model.error = nil } } message: { Text(model.error ?? "") }
        }
    }
}

