import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        statusBarController = StatusBarController(appState: AppState.shared)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.stop()
    }
}
