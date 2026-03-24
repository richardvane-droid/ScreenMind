import SwiftUI
import ScreenMindCore

@main
struct ScreenMindIOSApp: App {

    @UIApplicationDelegateAdaptor(IOSAppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext,
                              PersistenceController.shared.container.viewContext)
        }
    }
}

// MARK: - App Delegate

final class IOSAppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Request HealthKit authorization at first launch
        Task {
            let hrv = HRVManager()
            try? await hrv.requestAuthorization()
        }
        // Register for remote notifications (Notification Service Extension needs this)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        application.registerForRemoteNotifications()
        return true
    }
}
