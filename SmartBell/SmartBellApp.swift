import SwiftUI

@main
struct SmartBellApp: App {
    @StateObject private var device = BLEDeviceManager()
    @StateObject private var store = WorkoutStore()

    var body: some Scene {
        WindowGroup {
            SmartBellRootView()
                .environmentObject(device)
                .environmentObject(store)
                .preferredColorScheme(.light)
        }
    }
}
