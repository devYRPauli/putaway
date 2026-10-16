import AppKit
import PutawayCore
import SwiftUI

@main
struct PutawayApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra("Putaway", systemImage: "tray.and.arrow.down") {
            Button("Tidy \(delegate.tidy.source.lastPathComponent)") { delegate.show(start: delegate.tidy.source) }
                .keyboardShortcut("t")
            Button("Open Putaway") { delegate.show() }
            Divider()
            Button("Undo Last Tidy") {
                delegate.tidy.undo()
                delegate.show()
            }
            Divider()
            Button("Quit Putaway") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let tidy = Tidy()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        // Opening the app from Finder or Launchpad should show something, not just a menu bar icon.
        show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        show()
        return false
    }

    func show(start folder: URL? = nil) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: TidyView(tidy: tidy)))
            window.title = "Putaway"
            window.setContentSize(NSSize(width: 720, height: 520))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        if let folder, !isBusy {
            tidy.start(folder: folder)
        }
    }

    private var isBusy: Bool {
        switch tidy.phase {
        case .planning, .review: true
        default: false
        }
    }

    /// Finder > right-click a folder > Services > Tidy with Putaway. Declared under NSServices in Info.plist.
    @objc func tidyFolder(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first else {
            error.pointee = "No folder was selected." as NSString
            return
        }
        show(start: url)
    }
}
