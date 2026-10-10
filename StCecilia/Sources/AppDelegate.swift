import UIKit
import UserNotifications

@main
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Resume a persisted ride if the app was terminated mid-ride
        // (mirrors Android's START_STICKY service restart).
        LocationTracker.shared.restore()
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = ViewController()
        window?.makeKeyAndVisible()
        return true
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// A schedule "tap to start tracking" notification was tapped.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let tab = response.notification.request.content.userInfo["schedTab"] as? String {
            LocationTracker.shared.pendingScheduledTab = tab
            // If the page is already loaded, start right away; otherwise
            // ViewController picks it up after the page finishes loading.
            DispatchQueue.main.async {
                _ = ViewController.shared?.startScheduledRideIfPending()
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
