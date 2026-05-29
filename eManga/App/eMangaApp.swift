import SwiftUI
import OSLog

@main
struct eMangaApp: App {
    @State private var viewModel = ConversionViewModel()
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceMode = .system

    init() {
        Logger.app.info("eManga launched — version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown", privacy: .public) (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?", privacy: .public))")
        viewModel.restoreOutputFolder()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .preferredColorScheme(appearanceMode.colorScheme)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 860, height: 560)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            AppSettingsView()
                .preferredColorScheme(appearanceMode.colorScheme)
        }
    }
}
