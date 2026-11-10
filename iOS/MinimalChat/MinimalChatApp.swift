import SwiftUI

@main
struct MinimalChatApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text("聊天正在准备中").font(.headline)
                Text("登录和消息功能尚未接入。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .navigationTitle("聊天")
        }
    }
}

