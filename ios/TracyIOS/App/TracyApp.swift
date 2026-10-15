import SwiftUI

@main
struct TracyApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var notifications = WorkdayNotifications()
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(notifications)
                .tint(Color("AccentColor"))
                .preferredColorScheme(appearance == "system" ? nil : (appearance == "dark" ? .dark : .light))
        }
    }
}
