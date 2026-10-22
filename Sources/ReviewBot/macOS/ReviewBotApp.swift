import SwiftUI

@main
struct ReviewBotApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            // The poll scheduler has to start when the app launches, not when someone first
            // opens the popover. `MenuBarView` is the popover's *content*, and SwiftUI does
            // not instantiate it until the icon is clicked — so an app started at login sat
            // idle indefinitely, reviewing nothing, until a human happened to click it. That
            // is the one configuration this app is built for, and the failure is silent:
            // the icon looks exactly the same as a bot that is watching.
            //
            // The label is the only view that is always rendered, so it is where the start
            // belongs. `AppModel.start()` guards on `hasStarted`, so it stays correct if
            // SwiftUI re-creates the label.
            Image(systemName: model.statusSymbol)
                .task { model.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
