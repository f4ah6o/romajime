import SwiftUI

@main
struct RomajimeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 460, minHeight: 280)
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Romajime")
                .font(.largeTitle)
                .fontWeight(.semibold)
            Text("macOS input method proof of concept")
                .foregroundStyle(.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Install the input method bundle from the build products, then enable Romajime in Keyboard settings.")
                Text("~/Library/Application Support/Romajime/memory.md is used for simple terminology replacement.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(24)
    }
}
