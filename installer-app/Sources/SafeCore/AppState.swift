import AppKit
import Foundation
import SwiftUI

enum Screen: Int, CaseIterable {
    case check, enrol, install, done

    var title: String {
        switch self {
        case .check: return "Check this Mac"
        case .enrol: return "Enrol box"
        case .install: return "Install"
        case .done: return "Finished"
        }
    }
}

enum StepState { case waiting, running, ok, failed }

struct InstallStep: Identifiable {
    let id: String
    var title: String
    var state: StepState = .waiting
}

struct CheckItem: Identifiable {
    let id = UUID()
    var ok: Bool
    var info = false
    var text: String
}

/// Paths and facts about the SafeCore install on this Mac. Everything here is readable
/// without administrator rights.
enum SafeCoreInstall {
    static let root = "/opt/safecore"
    static let ctl = "/opt/safecore/scripts/safecorectl"
    static let installedApp = "/Applications/SafeCore.app"

    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: ctl) }

    /// safecore-setup writes etc/enrolled, but etc/ is private to the service account. Its
    /// LaunchDaemons are world-readable and only exist once a box has been enrolled.
    static var isEnrolled: Bool {
        FileManager.default.fileExists(atPath: "\(root)/etc/enrolled")
            || FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/ai.safecore.safecored.plist")
    }

    /// Version of the installed SafeCore package, from the macOS package receipt.
    static var installedVersion: String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        p.arguments = ["--pkg-info", "ai.safecore.aibox"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.components(separatedBy: "\n").first { $0.hasPrefix("version: ") }.map { String($0.dropFirst(9)) }
    }
}

enum AppMode { case installer, control }

@MainActor
final class AppState: ObservableObject {
    @Published var mode: AppMode
    @Published var screen: Screen = .check
    @Published var checks: [CheckItem] = []
    @Published var canContinue = false
    @Published var isUpgrade = false
    @Published var installedVersion: String?

    // Enrolment answers, in the order safecore-setup takes them.
    @Published var endpoint = ""
    @Published var tenantID = ""
    @Published var boxID = ""
    @Published var domain = ""
    @Published var accessKey = ""

    @Published var steps: [InstallStep] = []
    @Published var log = ""
    @Published var showLog = false
    @Published var installing = false
    @Published var errorMessage: String?

    let info = Bundle.main.infoDictionary ?? [:]
    var version: String { info["CFBundleShortVersionString"] as? String ?? "1.0.0" }
    var supportedArchs: [String] {
        (info["SafeCoreSupportedArchs"] as? String ?? "arm64,x86_64").split(separator: ",").map(String.init)
    }
    var pkgPath: String? { Bundle.main.path(forResource: "SafeCore", ofType: "pkg") }
    nonisolated static var runningFromDMG: Bool { Bundle.main.bundlePath.hasPrefix("/Volumes/") }

    init() {
        endpoint = info["SafeCoreDefaultEndpoint"] as? String ?? ""
        domain = info["SafeCoreDefaultDomain"] as? String ?? ""
        // The installed copy opens as the control panel; the copy on the DMG is the installer.
        let installedCopy = SafeCoreInstall.isInstalled && SafeCoreInstall.isEnrolled && !Self.runningFromDMG
        // `-SafeCoreForceControl YES` opens the control panel anywhere (for testing the UI).
        mode = (installedCopy || UserDefaults.standard.bool(forKey: "SafeCoreForceControl")) ? .control : .installer
        if mode == .installer { runChecks() }
    }

    // MARK: Step 1

    static var machineArch: String {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0, value == 1 { return "arm64" }
        return "x86_64"
    }

    func runChecks() {
        var items: [CheckItem] = []
        var ok = true

        let v = ProcessInfo.processInfo.operatingSystemVersion
        items.append(CheckItem(ok: true, text: "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"))

        let arch = Self.machineArch
        let chip = arch == "arm64" ? "Apple silicon (arm64)" : "Intel (x86_64)"
        if supportedArchs.contains(arch) {
            items.append(CheckItem(ok: true, text: "\(chip), supported"))
        } else {
            ok = false
            items.append(CheckItem(ok: false, text: "\(chip) is not supported by SafeCore \(version) yet. Contact SafeSpace support."))
        }

        if let free = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            let gb = Double(free) / 1_000_000_000
            let enough = gb >= 5
            ok = ok && enough
            items.append(CheckItem(ok: enough, text: enough ? String(format: "%.0f GB free on the startup disk", gb)
                                                            : String(format: "Only %.1f GB free. SafeCore needs at least 5 GB.", gb)))
        }

        if pkgPath == nil {
            ok = false
            items.append(CheckItem(ok: false, text: "The SafeCore package is missing from this app. Download the installer again."))
        }

        installedVersion = SafeCoreInstall.installedVersion
        isUpgrade = SafeCoreInstall.isInstalled && SafeCoreInstall.isEnrolled
        let text: String
        if isUpgrade {
            let from = installedVersion.map { "from \($0) " } ?? ""
            text = installedVersion == version
                ? "SafeCore \(version) is already installed and enrolled. Reinstalling keeps all settings and data."
                : "SafeCore is installed and enrolled. This upgrades it \(from)to \(version) and keeps all settings and data."
        } else if SafeCoreInstall.isInstalled {
            text = "SafeCore is installed but this box is not enrolled yet. You will enrol it in the next step."
        } else {
            text = "No SafeCore found in /opt/safecore. This is a fresh install."
        }
        items.append(CheckItem(ok: true, info: true, text: text))

        checks = items
        canContinue = ok
    }

    var continueTitle: String {
        guard isUpgrade else { return "Continue" }
        return installedVersion == version ? "Reinstall" : "Upgrade"
    }

    func continueFromChecks() {
        if isUpgrade { startInstall() } else { screen = .enrol }
    }

    // MARK: Step 2

    var formErrors: [String] {
        var e: [String] = []
        let ep = endpoint.trimmingCharacters(in: .whitespaces)
        if let u = URL(string: ep), let scheme = u.scheme, ["http", "https", "ws", "wss"].contains(scheme), u.host != nil {} else {
            e.append("Config API endpoint must be a full URL, e.g. https://…")
        }
        if tenantID.trimmingCharacters(in: .whitespaces).isEmpty { e.append("Tenant ID is required.") }
        if boxID.trimmingCharacters(in: .whitespaces).isEmpty { e.append("Box ID is required.") }
        if domain.trimmingCharacters(in: .whitespaces).isEmpty { e.append("Domain is required.") }
        if accessKey.isEmpty { e.append("Access key is required.") }
        if [endpoint, tenantID, boxID, domain, accessKey].contains(where: { $0.contains("\n") }) { e.append("Fields cannot contain line breaks.") }
        return e
    }

    // MARK: Step 3

    func startInstall() {
        guard let pkg = pkgPath, !installing else { return }
        errorMessage = nil
        log = ""
        steps = [
            InstallStep(id: "pkg", title: isUpgrade ? "Upgrade package in /opt/safecore" : "Install package into /opt/safecore"),
            InstallStep(id: "enrol", title: isUpgrade ? "Keep enrolment and bring services back" : "Enrol box, set up the database and start services"),
            InstallStep(id: "watchdog", title: "Turn on auto-restart"),
            InstallStep(id: "verify", title: "Check that everything is running"),
        ]
        screen = .install
        installing = true

        Task {
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("safecore-\(UUID().uuidString)")
            let progress = work.appendingPathComponent("progress.log")
            do {
                try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                fm.createFile(atPath: progress.path, contents: nil, attributes: [.posixPermissions: 0o600])
                if !isUpgrade {
                    let answers = [endpoint, tenantID, boxID, domain].map { $0.trimmingCharacters(in: .whitespaces) } + [accessKey]
                    fm.createFile(atPath: work.appendingPathComponent("answers").path,
                                  contents: Data((answers.joined(separator: "\n") + "\n").utf8),
                                  attributes: [.posixPermissions: 0o600])
                }
                accessKey = ""

                let poller = Task {
                    while !Task.isCancelled {
                        self.readProgress(progress)
                        try? await Task.sleep(nanoseconds: 400_000_000)
                    }
                }
                defer { poller.cancel() }

                var args = ["install", pkg, work.path, isUpgrade ? "upgrade" : "fresh"]
                if Self.runningFromDMG { args.append(Bundle.main.bundlePath) }
                _ = try await Privileged.runHelper(args)
                readProgress(progress)
                installing = false
                try? fm.removeItem(at: work)
                screen = .done
            } catch {
                readProgress(progress)
                try? fm.removeItem(at: work)
                installing = false
                if let i = steps.firstIndex(where: { $0.state == .running }) { steps[i].state = .failed }
                if case PrivilegedError.cancelled = error {
                    errorMessage = "Administrator access was cancelled. Nothing was changed."
                } else {
                    let name = steps.first(where: { $0.state == .failed })?.title ?? "Installation"
                    errorMessage = "\(name) failed. See the details below, or the full log in /Library/Logs/SafeCore/installer.log."
                    showLog = true
                }
            }
        }
    }

    private func readProgress(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var out: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("STEP ") {
                let parts = line.split(separator: " ")
                guard parts.count == 3, let i = steps.firstIndex(where: { $0.id == parts[1] }) else { continue }
                steps[i].state = parts[2] == "ok" ? .ok : parts[2] == "fail" ? .failed : .running
            } else if !line.hasPrefix("DONE") && !line.hasPrefix("FAIL ") {
                out.append(line)
            }
        }
        log = out.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    var progressFraction: Double {
        guard !steps.isEmpty else { return 0 }
        let done = Double(steps.filter { $0.state == .ok }.count)
        let half = steps.contains { $0.state == .running } ? 0.5 : 0
        return (done + half) / Double(steps.count)
    }

    // MARK: Step 4

    /// OK on the success screen: open the installed SafeCore app (the control panel), then quit
    /// this installer and eject its disk image, so only one SafeCore is left.
    func finish() {
        let installed = URL(fileURLWithPath: SafeCoreInstall.installedApp)
        guard Self.runningFromDMG, FileManager.default.fileExists(atPath: installed.path) else {
            mode = .control
            return
        }
        let volume = "/Volumes/" + (Bundle.main.bundlePath.dropFirst("/Volumes/".count).split(separator: "/").first.map(String.init) ?? "")
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = [AppDelegate.fromInstallerFlag]
        NSWorkspace.shared.openApplication(at: installed, configuration: config) { _, _ in
            DispatchQueue.main.async {
                // Eject once this process has exited and released the volume.
                let eject = Process()
                eject.executableURL = URL(fileURLWithPath: "/bin/sh")
                eject.arguments = ["-c", "sleep 2; /usr/bin/hdiutil detach \"$0\" -quiet || /usr/bin/hdiutil detach \"$0\" -force -quiet", volume]
                try? eject.run()
                NSApp.terminate(nil)
            }
        }
    }
}
