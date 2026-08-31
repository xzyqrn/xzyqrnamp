import SwiftUI

@main
struct XzyqrnAmpApp: App {
    @StateObject private var session = AmpSession()
    @StateObject private var bassMethod = BassMethodLibrary()
    @StateObject private var tabs = TabLibraryStore()
    @StateObject private var practice = PracticeSessionStore()

    var body: some Scene {
        WindowGroup {
            AmpView()
                .environmentObject(session)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 800)

        Window("Bass Method", id: "bass-method") {
            BassMethodLessonView()
                .environmentObject(bassMethod)
        }
        .defaultSize(width: 1180, height: 820)

        Window("Practice Lab", id: "practice") {
            PracticeLabView()
                .environmentObject(session)
                .environmentObject(bassMethod)
                .environmentObject(tabs)
                .environmentObject(practice)
        }
        .defaultSize(width: 1180, height: 820)

        Window("Bass Tabs", id: "tabs") {
            TabLibraryView()
                .environmentObject(tabs)
        }
        .defaultSize(width: 1120, height: 760)

        Settings {
            SettingsSheet()
                .environmentObject(session)
                .frame(width: 460, height: 580)
        }
    }
}
