import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct DBrewApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = BrewModel()

    var body: some Scene {
        Window("D-Brew", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 680, minHeight: 380)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan") { model.scan() }
                    .keyboardShortcut("r")
                    .disabled(model.isBusy)
                Divider()
                Button("Update Selected") { model.upgradeSelected() }
                    .keyboardShortcut("u")
                    .disabled(model.selectedPackages.isEmpty || model.isBusy)
                Button("Update All") { model.upgradeAll() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled(model.upgradable.isEmpty || model.isBusy)
                Divider()
                Button("Show Output") { model.showLog = true }
                    .keyboardShortcut("l")
                    .disabled(model.log.isEmpty)
            }
        }
    }
}
