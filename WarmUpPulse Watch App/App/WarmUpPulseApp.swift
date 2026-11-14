import SwiftUI

@main
struct WarmUpPulseApp: App {
    @State private var flow: AppFlow

    init() {
        AppSettings.registerDefaults()
        PhoneConnector.shared.activate()
        _flow = State(initialValue: AppFlow())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(flow)
        }
    }
}
