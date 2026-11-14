// Lumber (native): Library → Record → Edit/Export, plus Recordings.

import SwiftUI

@main
struct LumberApp: App {
    @State private var model = AppModel(services: Services.live())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            Group {
                if model.loaded {
                    LibraryScreen()
                } else {
                    ProgressView()
                        .tint(Theme.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.surface.ignoresSafeArea())
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .record(let songId):
                    RecordScreen(songId: songId)
                case .edit(let projectId):
                    EditScreen(projectId: projectId)
                case .recordings(let openId):
                    RecordingsScreen(openId: openId)
                }
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .task { await model.load() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.saveNow() }
        }
    }
}
