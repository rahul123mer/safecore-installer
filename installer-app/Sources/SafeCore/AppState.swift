import Foundation
import SwiftUI

enum Screen: Int, CaseIterable {
    case check, enrol, install, running

    var title: String {
        switch self {
        case .check: return "Check this Mac"
        case .enrol: return "Enrol box"
        case .install: return "Install"
        case .running: return "Running"
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

/// Numbers read from `safecorectl status`. Any value it cannot find stays nil and shows as "—".
/// Expected lines (see /opt/safecore/scripts/safecorectl):
///   ai.safecore.postgres     running
///   ai.safecore.safecored    running
///   services running: a, b, c
///   services starting: d (alive, not ready yet; …)
///   services stopped: -
///   weapon models: 3/3   cameras streaming: 12/14 (…)
struct StatusSummary {
    var servicesRunning: Int?
    var servicesTotal: Int?
    var servicesStarting = 0
    var daemonsDown: [String] = []
    var models: Int?
    var modelsTotal: Int?
    var camerasLive: Int?
    var camerasConfigured: Int?

    var allRunning: Bool {
        guard let r = servicesRunning, let t = servicesTotal, t > 0 else { return false }
        return r == t && daemonsDown.isEmpty
    }

    static func parse(_ text: String) -> StatusSummary {
        var s = StatusSummary()
        var running = 0, starting = 0, stopped = 0, sawServices = false
        func count(_ list: String) -> Int {
            let names = list.split(separator: "(").first.map(String.init) ?? list
            return names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "-" }.count
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("ai.safecore.postgres") || line.hasPrefix("ai.safecore.safecored") {
                if line.contains("stopped") { s.daemonsDown.append(String(line.split(separator: " ")[0])) }
            } else if line.hasPrefix("services running:") {
                sawServices = true; running = count(String(line.dropFirst("services running:".count)))
            } else if line.hasPrefix("services starting:") {
                sawServices = true; starting = count(String(line.dropFirst("services starting:".count)))
            } else if line.hasPrefix("services stopped:") {
                sawServices = true; stopped = count(String(line.dropFirst("services stopped:".count)))
            }
            if let m = firstMatch(#"weapon models:\s*(\d+)\s*/\s*(\d+)"#, in: line) {
                s.models = m[0]; s.modelsTotal = m[1]
            }
            if let m = firstMatch(#"cameras streaming:\s*(\d+)\s*/\s*(\d+)"#, in: line) {
                s.camerasLive = m[0]; s.camerasConfigured = m[1]
            }
        }
        if sawServices {
            s.servicesRunning = running
            s.servicesStarting = starting
            s.servicesTotal = running + starting + stopped
        }
        return s
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [Int]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<m.numberOfRanges).compactMap { i in
            Range(m.range(at: i), in: text).flatMap { Int(text[$0]) }
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    static let ctlPath = "/opt/safecore/scripts/safecorectl"

    @Published var screen: Screen = .check
    @Published var checks: [CheckItem] = []
    @Published var canContinue = false
    @Published var isUpgrade = false

    // Enrolment answers, in the order safecore-setup asks for them.
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

    @Published var statusText = ""
    @Published var status = StatusSummary()
    @Published var statusTime: Date?
    @Published var busy = false
    @Published var confirmStop = false

    let info = Bundle.main.infoDictionary ?? [:]
    var version: String { info["CFBundleShortVersionString"] as? String ?? "1.0.0" }
    var supportedArchs: [String] {
        (info["SafeCoreSupportedArchs"] as? String ?? "arm64,x86_64").split(separator: ",").map(String.init)
    }
    var pkgPath: String? { Bundle.main.path(forResource: "SafeCore", ofType: "pkg") }
    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: Self.ctlPath) }
    /// Written by safecore-setup once a box is enrolled. An upgrade of an enrolled box needs no enrolment.
    var isEnrolled: Bool { FileManager.default.fileExists(atPath: "/opt/safecore/etc/enrolled") }
    var runningFromDMG: Bool { Bundle.main.bundlePath.hasPrefix("/Volumes/") }

    init() {
        endpoint = info["SafeCoreDefaultEndpoint"] as? String ?? ""
        domain = info["SafeCoreDefaultDomain"] as? String ?? ""
        // Opened from Applications on a box that is already set up: go straight to the control panel.
        if isInstalled && !runningFromDMG {
            screen = .running
            Task { await refreshStatus() }
        } else {
            runChecks()
        }
    }

    // MARK: Step 1

    static var machineArch: String {
        var size = 0
        sysctlbyname("hw.optional.arm64", nil, &size, nil, 0)
        var value: Int32 = 0
        if size > 0, sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0, value == 1 { return "arm64" }
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

        let url = URL(fileURLWithPath: "/")
        if let free = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
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

        isUpgrade = isInstalled && isEnrolled
        items.append(CheckItem(ok: true, info: true, text: isUpgrade
            ? "SafeCore is already installed and enrolled. This will upgrade it to \(version) and keep all settings and data."
            : isInstalled ? "SafeCore is installed but this box is not enrolled yet. You will enrol it in the next step."
                          : "No SafeCore found in /opt/safecore. This is a fresh install."))

        checks = items
        canContinue = ok
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
            InstallStep(id: "verify", title: "Check that everything is running"),
        ]
        screen = .install
        installing = true

        Task {
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("safecore-\(UUID().uuidString)")
            do {
                try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let progress = work.appendingPathComponent("progress.log")
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
                if runningFromDMG { args.append(Bundle.main.bundlePath) }
                _ = try await Privileged.runHelper(args)
                readProgress(progress)
                installing = false
                try? fm.removeItem(at: work)
                screen = .running
                await refreshStatus()
            } catch {
                readProgress(work.appendingPathComponent("progress.log"))
                try? fm.removeItem(at: work)
                installing = false
                if let i = steps.firstIndex(where: { $0.state == .running }) { steps[i].state = .failed }
                if case PrivilegedError.cancelled = error {
                    errorMessage = "Administrator access was cancelled. Nothing was changed."
                } else {
                    errorMessage = failureText
                    showLog = true
                }
            }
        }
    }

    private var failureText: String {
        let name = steps.first(where: { $0.state == .failed })?.title ?? "Installation"
        return "\(name) failed. See the details below, or the full log in /Library/Logs/SafeCore/installer.log."
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

    // MARK: Step 4 / control panel

    func refreshStatus() async { await control("status") }

    func control(_ action: String) async {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        defer { busy = false }
        do {
            var text = try await Privileged.runHelper([action])
            if let r = text.range(of: "@@STATUS@@") { text = String(text[r.upperBound...]) }
            statusText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            status = StatusSummary.parse(statusText)
            statusTime = Date()
        } catch PrivilegedError.cancelled {
            errorMessage = "Administrator access was cancelled."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
