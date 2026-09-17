import SwiftUI
import AppKit

@main
struct CrateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("Crate", id: "main") {
            ContentView()
                .environmentObject(delegate.settings)
                .environmentObject(delegate.packager)
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Load Files or Folder…") { delegate.packager.choose() }
                    .keyboardShortcut("o")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = Settings()
    lazy var packager = Packager(settings: settings)

    private lazy var services = FinderService(packager: packager)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--package"), i + 1 < args.count else { return }
        let url = URL(fileURLWithPath: args[i + 1])
        packager.interactive = false
        Task {
            await packager.load([url])
            await packager.run(zip: args.contains("--zip"))
            print(packager.message)
            if let out = packager.output { print(out.path) }
            NSApp.terminate(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { await packager.load(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@MainActor
final class FinderService: NSObject {
    let packager: Packager

    init(packager: Packager) {
        self.packager = packager
    }

    @objc func packageFolder(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(pboard, zip: false)
    }

    @objc func packageAndZip(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(pboard, zip: true)
    }

    private func handle(_ pboard: NSPasteboard, zip: Bool) {
        let urls = pboard.readObjects(forClasses: [NSURL.self],
                                      options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty, !packager.running else { return }
        NSApp.activate()
        Task {
            await packager.load(urls)
            if packager.settings.config.finderImmediate {
                await packager.run(zip: zip)
            }
        }
    }
}
