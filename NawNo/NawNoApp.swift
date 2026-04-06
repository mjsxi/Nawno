import SwiftUI

@main
struct NawNoApp: App {
    @State private var store = ModelStore()
    @State private var llm = LLMService()
    @State private var downloader = HFDownloadService()
    @State private var chatStore = ChatStore()
    @State private var updateService = UpdateService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(llm)
                .environment(downloader)
                .environment(chatStore)
                .environment(updateService)
                .task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await updateService.checkForUpdates()
                }
        }
        .defaultSize(width: 900, height: 650)
        .windowToolbarStyle(.unified)

        WindowGroup(id: "download") {
            DownloadWindowView()
                .environment(store)
                .environment(downloader)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
    }
}
