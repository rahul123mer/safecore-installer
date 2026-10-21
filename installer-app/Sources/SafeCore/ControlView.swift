import SwiftUI

struct ControlView: View {
    @StateObject private var model = ControlModel()
    @State private var confirmStop = false

    var body: some View {
        VStack(spacing: 0) {
            header
            actionBar
            Divider()
            HStack(spacing: 0) {
                serviceList.frame(width: 430)
                Divider()
                detailPane
            }
            Divider()
            footer
        }
        .frame(width: 960, height: 660)
        .onAppear { model.start() }
        .confirmationDialog("Stop SafeCore?", isPresented: $confirmStop) {
            Button("Stop everything", role: .destructive) { Task { await model.run("stop") } }
        } message: {
            Text("This stops all services, the WebSocket relay and the database. Auto-restart will not bring them back. They stay stopped until you press Start or the Mac restarts.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(Brand.gradient)
                SafeSpaceMark().foregroundStyle(.white).padding(6)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("SafeCore Control").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                Text(identityLine).font(.system(size: 12)).foregroundStyle(Brand.sideText)
            }
            Spacer()
            StatusPill(text: model.overall.title, health: model.overall.health, onDark: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Brand.sidebar)
    }

    private var identityLine: String {
        var parts: [String] = []
        if let b = model.boxID { parts.append("Box \(b)") }
        if let t = model.tenant { parts.append("Tenant \(t)") }
        parts.append("SafeCore \(SafeCoreInstall.installedVersion ?? "")")
        return parts.joined(separator: " · ")
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button { Task { await model.run("start") } } label: { Label("Start", systemImage: "play.fill") }
            Button { Task { await model.run("restart") } } label: { Label("Restart", systemImage: "arrow.clockwise") }
            Button(role: .destructive) { confirmStop = true } label: { Label("Stop", systemImage: "stop.fill") }
            if let busy = model.busyAction {
                ProgressView().controlSize(.small).padding(.leading, 6)
                Text(busyText(busy)).font(.system(size: 12)).foregroundStyle(.secondary)
            } else if let msg = model.message {
                Label(msg, systemImage: model.messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(model.messageIsError ? Color.red : Color.green)
                    .lineLimit(2)
            }
            Spacer()
            Text("Updated \(model.lastUpdate?.formatted(date: .omitted, time: .standard) ?? "—")")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .disabled(model.busyAction != nil)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func busyText(_ action: String) -> String {
        switch action {
        case "start": return "Starting SafeCore. This can take up to 3 minutes…"
        case "restart": return "Restarting SafeCore. This can take up to 3 minutes…"
        case "stop": return "Stopping SafeCore…"
        default: return "Working…"
        }
    }

    // MARK: Service list

    private var serviceList: some View {
        List(selection: Binding(get: { model.selected }, set: { model.selected = $0; if let k = $0 { model.loadLog(for: k) } })) {
            Section("Core") {
                ForEach(model.core) { row in ServiceRowView(row: row).tag(row.key) }
            }
            Section("Services (\(model.services.filter { $0.health == .online }.count) of \(model.services.count) online)") {
                if model.services.isEmpty {
                    Text("No services have been started yet. Press Start.").foregroundStyle(.secondary).font(.system(size: 12))
                }
                ForEach(model.services) { row in ServiceRowView(row: row).tag(row.key) }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
    }

    // MARK: Details

    @ViewBuilder private var detailPane: some View {
        if let key = model.selected, let row = (model.core + model.services).first(where: { $0.key == key }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(row.title).font(.system(size: 18, weight: .bold))
                    Spacer()
                    StatusPill(text: row.health.label, health: row.health)
                }
                Text(row.detail).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow { Text("Name").foregroundStyle(.secondary); Text(row.key).textSelection(.enabled) }
                    GridRow { Text("Process ID").foregroundStyle(.secondary); Text(row.pid.map(String.init) ?? "—") }
                    GridRow { Text("Running for").foregroundStyle(.secondary); Text(row.uptime ?? "—") }
                    if let note = row.note { GridRow { Text("Connection").foregroundStyle(.secondary); Text(note) } }
                }
                .font(.system(size: 12))
                HStack {
                    Text("Recent log").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if let path = row.logPath {
                        Button("Open full log") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }.controlSize(.small)
                    }
                }
                ScrollView {
                    Text(model.logText.isEmpty ? "No log output." : model.logText)
                        .font(.system(size: 10.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sidebar.left").font(.system(size: 28)).foregroundStyle(.tertiary)
                Text("Select a service to see its details and log.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(alignment: .top, spacing: 12) {
            autoRestartCard
            Metric(value: model.models, label: "Weapon models opened")
            Metric(value: model.cameras, label: "Cameras live / configured")
        }
        .padding(14)
    }

    private var autoRestartCard: some View {
        let on = model.watchdogInstalled && (model.watchdog?.enabled ?? true)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Brand.blue)
                Text("Auto-restart").font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("", isOn: Binding(get: { on }, set: { v in Task { await model.run(v ? "watchdog-on" : "watchdog-off") } }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .disabled(model.busyAction != nil)
            }
            Text(autoRestartText).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private var autoRestartText: String {
        guard model.watchdogInstalled else { return "Not installed on this box. Turn it on to restart services that stop on their own." }
        guard let w = model.watchdog else { return "Waiting for the first check…" }
        var lines: [String] = []
        switch w.mode {
        case "disabled": lines.append("Off. Services that stop on their own stay stopped.")
        case "stopped": lines.append("Paused while SafeCore is stopped by you.")
        case "paused": lines.append(w.detail)
        default: lines.append("On. Checks every 30 seconds and restarts services that stop on their own.")
        }
        if w.lastRestart > 0 {
            let d = Date(timeIntervalSince1970: w.lastRestart)
            lines.append("Last automatic restart \(d.formatted(date: .abbreviated, time: .shortened)): \(w.lastRestartReason)")
        }
        return lines.joined(separator: "\n")
    }
}

struct ServiceRowView: View {
    let row: ServiceRow

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(row.health.color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.system(size: 13, weight: .medium))
                Text(row.note ?? row.key).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(row.health.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(row.health.color)
                Text(row.uptime.map { "up \($0)" } ?? " ").font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 3)
    }
}

struct StatusPill: View {
    let text: String
    let health: ServiceHealth
    var onDark = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(health.color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12, weight: .semibold))
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(health.color.opacity(onDark ? 0.22 : 0.14)))
        .foregroundStyle(onDark ? Color.white : health.color)
    }
}

struct Metric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .bold)).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 170, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

extension ServiceHealth {
    var color: Color {
        switch self {
        case .online: return .green
        case .starting: return .orange
        case .offline: return .red
        case .stopped: return .gray
        }
    }
}
