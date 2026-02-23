import SwiftUI

@main
struct FormatKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Enable Extension") {
                    appDelegate.presentExtensionOnboardingWindow()
                }
            }
        }
    }
}
