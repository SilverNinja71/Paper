// iPad app entry point. Not part of Package.swift (this Mac has no iOS SDK): add it to an Xcode
// "App" project (iOS 17+) that links the PaperCore library from this package — see README.md, "iPad".

import SwiftUI
import PaperCore

@main
struct PaperiPadApp: App {
    @State private var model = PaperAppModel(cloud: CloudSyncController.live())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            PaperRootView(model: model)
                .onOpenURL { url in
                    switch url.pathExtension.lowercased() {
                    case "paper": model.open(url)
                    case "abr", "paperbrush", "paperbrushset": model.importBrushes(url)
                    default: model.newDocument(fromPhoto: url)
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Save (and let cloud sync upload) as soon as the app leaves the foreground.
            if phase == .background { model.appWillSuspend() }
            if phase == .active { model.cloud?.syncNow() }
        }
    }
}
