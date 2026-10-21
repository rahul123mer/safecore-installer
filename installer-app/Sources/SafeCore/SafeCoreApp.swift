import AppKit
import SwiftUI

@main
struct SafeCoreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("SafeCore", id: "main") {
            Group {
                switch state.mode {
                case .installer: InstallerView()
                case .control: ControlView()
                }
            }
            .environmentObject(state)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Passed by the installer when it opens the installed app at the end, so the new
    /// copy does not hand control back to the installer that is about to quit.
    static let fromInstallerFlag = "--from-installer"

    func applicationWillFinishLaunching(_ notification: Notification) {
        enforceSingleInstance()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Only one SafeCore runs at a time.
    /// - The same copy opened again: bring the running one forward and quit.
    /// - The installer (on the DMG) opened while the installed app runs: close the installed
    ///   app so the installer can replace it.
    /// - The installed app opened while the installer runs: bring the installer forward.
    private func enforceSingleInstance() {
        guard let id = Bundle.main.bundleIdentifier,
              !CommandLine.arguments.contains(Self.fromInstallerFlag) else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return }

        let iAmInstaller = AppState.runningFromDMG
        for other in others {
            let otherIsInstaller = other.bundleURL?.path.hasPrefix("/Volumes/") ?? false
            if iAmInstaller && !otherIsInstaller {
                other.terminate()
                let deadline = Date().addingTimeInterval(5)
                while !other.isTerminated && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
                if !other.isTerminated { other.forceTerminate() }
            } else {
                other.activate()
                exit(0)
            }
        }
    }
}
