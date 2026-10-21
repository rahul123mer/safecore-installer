import AppKit
import Foundation

enum ServiceHealth: Equatable {
    case online, starting, offline, stopped

    var label: String {
        switch self {
        case .online: return "Online"
        case .starting: return "Starting"
        case .offline: return "Offline"
        case .stopped: return "Stopped"
        }
    }
}

struct ServiceRow: Identifiable, Equatable {
    var id: String { key }
    let key: String          // name in status.json / health report, or a core component id
    let title: String
    let detail: String       // what it does
    var health: ServiceHealth
    var pid: Int?
    var uptime: String?
    var note: String?        // e.g. WebSocket connection state
    var logPath: String?
}

/// What the watchdog last wrote to /Library/Application Support/SafeCore/watchdog-status.json.
struct WatchdogStatus: Decodable {
    var updated: Double
    var enabled: Bool
    var mode: String
    var detail: String
    var websocketOK: Bool
    var websocketDetail: String
    var lastRestart: Double
    var lastRestartReason: String
    var restartsLastHour: Int
}

/// Live view of the SafeCore box for the control panel. Everything is read without
/// administrator rights; only Start / Stop / Restart / auto-restart changes ask for the password.
@MainActor
final class ControlModel: ObservableObject {
    static let root = SafeCoreInstall.root
    static let watchdogStatusPath = "/Library/Application Support/SafeCore/watchdog-status.json"
    static let watchdogPlist = "/Library/LaunchDaemons/ai.safespaceglobal.safecore-watchdog.plist"

    @Published var core: [ServiceRow] = []
    @Published var services: [ServiceRow] = []
    @Published var cameraRows: [ServiceRow] = []
    @Published var overall: (title: String, health: ServiceHealth) = ("Checking…", .starting)
    @Published var models: String = "—"
    @Published var cameras: String = "—"
    @Published var boxID: String?
    @Published var tenant: String?
    @Published var watchdog: WatchdogStatus?
    @Published var watchdogInstalled = false
    @Published var lastUpdate: Date?
    @Published var busyAction: String?
    @Published var message: String?
    @Published var messageIsError = false
    @Published var selected: String?
    @Published var logText = ""

    private var timer: Timer?

    /// What each service does, for the details pane. Unknown services still show with their raw name.
    static let descriptions: [String: (String, String)] = [
        "orchestrator": ("Orchestrator", "Coordinates the cameras and analytics pipelines."),
        "config_generator": ("Config generator", "Builds camera and service configuration from the portal."),
        "alerts_router": ("Alerts router", "Sends detections and alerts to SafeSpace."),
        "weapon_pipeline": ("Weapon detection", "Runs the gun and knife models on camera frames."),
        "syncapi": ("Sync API", "Local API that keeps the box in sync with the portal."),
        "disk_janitor": ("Disk janitor", "Cleans up old recordings so the disk does not fill."),
        "health_uploader": ("Health uploader", "Reports box and service health to SafeSpace."),
        "homography_uploader": ("Homography uploader", "Uploads camera calibration data."),
        "safecore_box_sync": ("Box sync", "Syncs box settings and state with SafeSpace."),
        "rtsp_csv_win": ("Camera streaming", "Pulls camera streams and publishes live video."),
        "pixtral": ("Pixtral", "Scene description service."),
    ]

    func start() {
        readIdentity()
        Task { await refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    // MARK: Reading state

    private func readIdentity() {
        // .env is written by safecore-setup. It holds the box identity, never the access key.
        guard let env = try? String(contentsOfFile: "\(Self.root)/.env", encoding: .utf8) else { return }
        for line in env.components(separatedBy: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let value = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if kv[0] == "SafeCoreBoxId" || kv[0] == "BOX_ID" { boxID = value }
            if kv[0] == "TENANT_ID" { tenant = value }
        }
    }

    private var refreshing = false

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let ready = await Self.healthReport()
        let procs = Self.processes()
        let launched = Self.launchedServices()
        watchdogInstalled = FileManager.default.fileExists(atPath: Self.watchdogPlist)
        watchdog = (try? Data(contentsOf: URL(fileURLWithPath: Self.watchdogStatusPath)))
            .flatMap { try? JSONDecoder().decode(WatchdogStatus.self, from: $0) }

        let pg = procs.first { $0.command.contains("/opt/safecore/pgsql/bin/postgres -D") }
        let sd = procs.first { $0.command.contains("/WebSocket/safecored/target/release/safecored") && !$0.command.contains("safecored-cli") }
        let launcherRunning = procs.contains { $0.command.contains("run_all_bins.sh") }
        let stoppedByUser = watchdog?.mode == "stopped" && sd == nil

        var wsNote: String?
        if let w = watchdog, sd != nil, Date().timeIntervalSince1970 - w.updated < 120 {
            wsNote = w.websocketOK ? "Answering" : "Not answering: \(w.websocketDetail)"
        }

        core = [
            ServiceRow(key: "postgres", title: "Database", detail: "PostgreSQL, stores events and configuration.",
                       health: pg != nil ? .online : (stoppedByUser ? .stopped : .offline),
                       pid: pg?.pid, uptime: pg?.elapsed, logPath: "\(Self.root)/var/pg/server.log"),
            ServiceRow(key: "safecored", title: "WebSocket relay (safecored)",
                       detail: "Keeps the live connection to SafeSpace and holds the box's keys.",
                       health: sd == nil ? (stoppedByUser ? .stopped : .offline) : (watchdog?.websocketOK == false && wsNote != nil ? .starting : .online),
                       pid: sd?.pid, uptime: sd?.elapsed, note: wsNote,
                       logPath: "\(Self.root)/WebSocket/safecored/logs/launchd.err.log"),
        ]

        var rows: [ServiceRow] = []
        for (name, pid) in launched {
            let proc = procs.first { $0.pid == pid && ($0.command.contains(".bin") || $0.command.contains("/opt/safecore")) }
            let health: ServiceHealth
            if proc == nil {
                health = stoppedByUser ? .stopped : .offline
            } else if let ready, !ready.contains(name) {
                health = .starting
            } else {
                health = .online
            }
            let (title, detail) = Self.descriptions[name] ?? (name, "SafeCore service.")
            rows.append(ServiceRow(key: name, title: title, detail: detail, health: health,
                                   pid: proc?.pid, uptime: proc?.elapsed,
                                   logPath: "\(Self.root)/logs/services/\(name).log"))
        }
        services = rows.sorted { $0.title < $1.title }

        // Weapon models and cameras, the same way safecorectl status counts them.
        if let log = try? String(contentsOfFile: "\(Self.root)/logs/services/weapon_pipeline.log", encoding: .utf8) {
            models = "\(log.components(separatedBy: "opened by safecored").count - 1)/3"
        }
        // Cameras: the enabled rows of LiveCameraFeeds (the list the streaming service reads),
        // live when the camera's HLS playlist was written in the last minute.
        let pgPort = pg.flatMap { Self.portArgument(in: $0.command) } ?? 5432
        let feeds = pg == nil ? nil : await Self.cameraFeeds(port: pgPort)
        let hls = "\(Self.root)/data/hls"
        func isLive(_ folder: String) -> Bool {
            let m = (try? FileManager.default.attributesOfItem(atPath: "\(hls)/\(folder)/index.m3u8"))?[.modificationDate] as? Date
            return m.map { Date().timeIntervalSince($0) < 60 } ?? false
        }
        let folders = ((try? FileManager.default.contentsOfDirectory(atPath: hls)) ?? []).filter { !$0.hasPrefix(".") }
        if let feeds {
            // Folders are expected to be named by camera_id. If none match, live state per camera is unknown.
            let perCamera = folders.isEmpty || feeds.contains { folders.contains($0.id) }
            cameraRows = feeds.map { feed in
                let live = perCamera && isLive(feed.id)
                return ServiceRow(key: "camera:\(feed.id)", title: feed.name.isEmpty ? feed.id : feed.name,
                                  detail: "Camera \(feed.id). Live means its video playlist was updated in the last minute.",
                                  health: !perCamera ? .starting : live ? .online : (stoppedByUser ? .stopped : .offline),
                                  note: !perCamera ? "Live state not available per camera" : live ? "Streaming" : "No video in the last minute",
                                  logPath: "\(Self.root)/logs/services/rtsp_csv_win.log")
            }
            let liveCount = perCamera ? cameraRows.filter { $0.health == .online }.count
                                      : min(folders.filter(isLive).count, feeds.count)
            cameras = "\(liveCount)/\(feeds.count)"
        } else {
            // Database not reachable: fall back to the camera folders, skipping hidden files.
            cameraRows = []
            cameras = folders.isEmpty ? "—" : "\(folders.filter(isLive).count)/\(folders.count)"
        }

        let all = core + services
        if stoppedByUser {
            overall = ("Stopped", .stopped)
        } else if launcherRunning || watchdog?.mode == "starting" || watchdog?.mode == "restarting" {
            overall = (watchdog?.mode == "restarting" ? "Restarting automatically" : "Starting", .starting)
        } else if all.allSatisfy({ $0.health == .online }) && !services.isEmpty {
            overall = ("All services online", .online)
        } else if all.contains(where: { $0.health == .offline }) {
            let n = all.filter { $0.health == .offline }.count
            overall = ("\(n) offline", .offline)
        } else {
            overall = ("Starting", .starting)
        }
        lastUpdate = Date()
        if let sel = selected { loadLog(for: sel) }
    }

    struct Proc { let pid: Int; let elapsed: String; let command: String }

    /// All processes, via ps (no administrator rights needed).
    static func processes() -> [Proc] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axww", "-o", "pid=,etime=,command="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).components(separatedBy: "\n").compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int(parts[0]) else { return nil }
            return Proc(pid: pid, elapsed: formatElapsed(String(parts[1])), command: String(parts[2]))
        }
    }

    /// ps etime ([[dd-]hh:]mm:ss) as "3d 4h", "2h 5m" or "12m".
    static func formatElapsed(_ e: String) -> String {
        var days = 0, rest = e
        if let dash = e.firstIndex(of: "-") { days = Int(e[..<dash]) ?? 0; rest = String(e[e.index(after: dash)...]) }
        let f = rest.split(separator: ":").compactMap { Int($0) }
        let (h, m) = f.count == 3 ? (f[0], f[1]) : (0, f.first ?? 0)
        if days > 0 { return "\(days)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(max(m, 0))m"
    }

    /// Services the launcher started, from /opt/safecore/status.json (name → pid).
    static func launchedServices() -> [(String, Int)] {
        guard let text = try? String(contentsOfFile: "\(root)/status.json", encoding: .utf8) else { return [] }
        let compact = text.filter { !$0.isWhitespace }
        guard let re = try? NSRegularExpression(pattern: #""([A-Za-z0-9_]+)":\{"pid":([0-9]+)"#) else { return [] }
        var seen = Set<String>()
        return re.matches(in: compact, range: NSRange(compact.startIndex..., in: compact)).compactMap { m in
            guard let n = Range(m.range(at: 1), in: compact), let p = Range(m.range(at: 2), in: compact),
                  let pid = Int(compact[p]) else { return nil }
            let name = String(compact[n])
            return seen.insert(name).inserted ? (name, pid) : nil
        }
    }

    /// The value after `-p` in the postgres command line (launchd expands SAFECORE_PG_PORT there).
    static func portArgument(in command: String) -> Int? {
        let parts = command.split(separator: " ")
        guard let i = parts.firstIndex(of: "-p"), i + 1 < parts.count else { return nil }
        return Int(parts[i + 1])
    }

    struct CameraFeed { let id: String; let name: String }

    /// Enabled cameras from the box database (local trust auth, read-only query).
    static func cameraFeeds(port: Int) async -> [CameraFeed]? {
        await Task.detached { () -> [CameraFeed]? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "\(SafeCoreInstall.root)/pgsql/bin/psql")
            p.arguments = ["-h", "127.0.0.1", "-p", String(port), "-U", "aibox_user", "-d", "aibox_ingestor",
                           "-X", "-q", "-t", "-A", "-F", "\t", "-c",
                           "SELECT l.camera_id, COALESCE(c.camera_name, '') FROM livecamerafeeds l "
                           + "LEFT JOIN cameras c USING (camera_id) WHERE l.enabled = 1 ORDER BY 2, 1"]
            p.environment = ["PGCONNECT_TIMEOUT": "2", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
                let f = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard let id = f.first, !id.isEmpty else { return nil }
                return CameraFeed(id: id, name: f.count > 1 ? f[1] : "")
            }
        }.value
    }

    /// Names the health uploader reports as running (ready), or nil if it is not answering.
    static func healthReport() async -> Set<String>? {
        guard let url = URL(string: "http://127.0.0.1:8013/stats/server") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = json["apps"] as? [String: Any], let info = apps["info"] as? [String: Any],
              let running = info["running_apps"] as? [String] else { return nil }
        return Set(running)
    }

    func loadLog(for key: String) {
        guard let row = (core + services + cameraRows).first(where: { $0.key == key }), let path = row.logPath else { logText = ""; return }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            logText = "Log not readable: \(path)"
            return
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 12_000 ? size - 12_000 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        logText = text.components(separatedBy: "\n").suffix(40).joined(separator: "\n")
    }

    // MARK: Actions (administrator prompt)

    func run(_ action: String) async {
        guard busyAction == nil else { return }
        busyAction = action
        message = nil
        defer { busyAction = nil; Task { await refresh() } }
        do {
            var out = try await Privileged.runHelper([action])
            if let r = out.range(of: "@@STATUS@@") { out = String(out[..<r.lowerBound]) }
            messageIsError = false
            switch action {
            case "start": message = "SafeCore started."
            case "stop": message = "SafeCore stopped. It stays stopped until you press Start or the Mac restarts."
            case "restart": message = "SafeCore restarted."
            case "watchdog-on": message = "Auto-restart is on."
            case "watchdog-off": message = "Auto-restart is off."
            default: message = out.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch PrivilegedError.cancelled {
            messageIsError = true
            message = "Administrator access was cancelled. Nothing was changed."
        } catch {
            messageIsError = true
            message = error.localizedDescription
        }
    }
}
