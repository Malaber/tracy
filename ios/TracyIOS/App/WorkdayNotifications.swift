import Combine
import Foundation
import UserNotifications
import TracyCore

struct CheckoutRequest: Identifiable {
    let id = UUID()
    let day: String
    let account: String
}

@MainActor
final class WorkdayNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var checkoutRequest: CheckoutRequest?
    @Published var permissionDenied = false
    @Published var error: String?
    private let center = UNUserNotificationCenter.current()
    private let prefix = "tracy.workday."
    private var generation = 0
    private var updateTask: Task<Void, Never>?

    override init() {
        super.init()
        center.delegate = self
        let action = UNNotificationAction(identifier: "checkout", title: "Review checkout", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(
            identifier: "workday", actions: [action], intentIdentifiers: [], options: []
        )])
    }

    func enable() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            permissionDenied = !granted
            return granted
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func synchronize(entry: WorkEntry, timezone: String, account: String?, enabled: Bool) async {
        generation += 1
        let version = generation
        let previous = updateTask
        let next = Task {
            await previous?.value
            guard version == generation else { return }
            await apply(entry: entry, timezone: timezone, account: account, enabled: enabled, version: version)
        }
        updateTask = next
        await next.value
        if version == generation { updateTask = nil }
    }

    private func apply(entry: WorkEntry, timezone: String, account: String?, enabled: Bool, version: Int) async {
        let pending = await center.pendingNotificationRequests()
        guard version == generation, !Task.isCancelled else { return }
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix(prefix) }.map(\.identifier))
        let delivered = await center.deliveredNotifications()
        guard version == generation, !Task.isCancelled else { return }
        center.removeDeliveredNotifications(withIdentifiers: delivered.filter {
            $0.request.identifier.hasPrefix(prefix) &&
                (!enabled || account == nil || $0.request.content.userInfo["account"] as? String != account ||
                 ($0.request.content.userInfo["day"] as? String == entry.date && (entry.checkOut != nil || entry.isDayOff)))
        }.map { $0.request.identifier })
        guard enabled, let account else { return }
        let settings = await center.notificationSettings()
        guard version == generation, !Task.isCancelled else { return }
        permissionDenied = settings.authorizationStatus == .denied
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        for reminder in WorkdayReminder.plan(entry: entry, timezone: timezone, now: Date()) {
            let content = UNMutableNotificationContent()
            content.title = reminder.kind == .automaticBreak ? "Time for a break" : "Eight hours worked"
            content.body = reminder.kind == .automaticBreak
                ? "I just added a 30-minute break to your total. You might want to take one if you haven’t already."
                : "You have been working for 8 hours now. Do you want to check out?"
            content.sound = .default
            content.categoryIdentifier = "workday"
            content.userInfo = ["day": reminder.day, "account": account]
            var date = Clock.calendar(timezone: timezone).dateComponents([.year, .month, .day, .hour, .minute], from: reminder.fireDate)
            date.timeZone = TimeZone(identifier: timezone)
            let request = UNNotificationRequest(
                identifier: prefix + account + "." + reminder.day + "." + reminder.kind.rawValue,
                content: content, trigger: UNCalendarNotificationTrigger(dateMatching: date, repeats: false))
            guard version == generation, !Task.isCancelled else { return }
            do { try await center.add(request) } catch { self.error = error.localizedDescription }
        }
    }

    func openCheckout(day: String, account: String) {
        guard WorkdayDates.date(day, timezone: "UTC") != nil else { return }
        checkoutRequest = CheckoutRequest(day: day, account: account)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let day = response.notification.request.content.userInfo["day"] as? String,
            let account = response.notification.request.content.userInfo["account"] as? String,
            WorkdayDates.date(day, timezone: "UTC") != nil else { return }
        await MainActor.run { self.openCheckout(day: day, account: account) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
