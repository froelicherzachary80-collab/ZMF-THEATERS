import SwiftUI

@main
struct ZMFTheatersApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.library)
                .environmentObject(model.wallet)
                .environmentObject(model.settingsStore)
                .environmentObject(model.rotation)
                .environmentObject(model.session)
                .environmentObject(model.game)
                .preferredColorScheme(.dark)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
                .task {
                    model.applyLaunchArguments()
                    await model.launch()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // Restores the correct 72-hour rotation after long periods closed.
                model.refreshProgramme()
                for msg in model.wallet.applyRewards(settings: model.settings) { model.flash(msg) }
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.mode == nil {
                TitleView()
            } else {
                GameView()
            }
        }
        .animation(.easeInOut(duration: 0.4), value: model.mode)
    }
}
