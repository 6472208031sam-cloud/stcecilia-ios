import UIKit
import UserNotifications
import BackgroundTasks

@main
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Background App Refresh must be registered BEFORE launch finishes
        // (BGTaskScheduler requirement); its handler re-arms the schedule.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID, using: nil) { task in
            Self.handleAppRefresh(task)
        }
        Self.scheduleAppRefresh()
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
        // The ride-start confirmation is quiet by design: no foreground
        // banner or sound — it waits in Notification Center.
        if notification.request.identifier == LocationTracker.startNotificationID {
            completionHandler([])
        } else {
            completionHandler([.banner, .sound])
        }
    }

    // MARK: - Background App Refresh (schedule safety net)

    /// Background-refresh task identifier — must match project.yml's
    /// BGTaskSchedulerPermittedIdentifiers and the `fetch` background mode.
    static let refreshTaskID = "io.github.stcecilia.refresh"

    /// Asks iOS for a background-refresh slot ~1h out. iOS alone decides
    /// if/when it runs: Background App Refresh is a user-controlled setting
    /// (Settings → General → Background App Refresh) and there is NO API to
    /// enable it or to prompt for it — so the app logs the current status
    /// instead of pretending to request a permission.
    static func scheduleAppRefresh() {
        let status = UIApplication.shared.backgroundRefreshStatus
        LocationTracker.shared.schedLog("backgroundRefreshStatus=\(status.rawValue) (0=restricted 1=denied/off 2=available)")
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            LocationTracker.shared.schedLog("BG refresh request submitted (earliest +1h)")
        } catch {
            LocationTracker.shared.schedLog("BG refresh submit FAILED: \(error.localizedDescription)")
        }
    }

    /// iOS woke the app for a background refresh: re-arm the schedule
    /// notifications from the stored settings, then book the next slot.
    private static func handleAppRefresh(_ task: BGTask) {
        guard let refreshTask = task as? BGAppRefreshTask else {
            task.setTaskCompleted(success: false)
            return
        }
        LocationTracker.shared.schedLog("BG refresh fired - re-arming schedule")
        refreshTask.expirationHandler = {
            LocationTracker.shared.schedLog("BG refresh expired before re-arm finished")
        }
        ScheduleManager.shared.schedule {
            scheduleAppRefresh()
            refreshTask.setTaskCompleted(success: true)
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        Self.scheduleAppRefresh()
    }
}
