import SwiftUI

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            VStack(alignment: .leading, spacing: 14) {
                switch state.screen {
                case .check: CheckView()
                case .enrol: EnrolView()
                case .install: InstallView()
                case .running: RunningView()
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 760, height: 500)
    }
}

struct Sidebar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(Brand.gradient)
                    SafeSpaceMark().foregroundStyle(.white).padding(5)
                }
                .frame(width: 28, height: 28)
                Text("SafeCore").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Screen.allCases, id: \.self) { s in
                    StepRow(index: s.rawValue + 1, title: s.title,
                            done: s.rawValue < state.screen.rawValue,
                            current: s == state.screen,
                            skipped: s == .enrol && state.isUpgrade)
                }
            }
            Spacer()
            Text("Version \(state.version) · Universal")
                .font(.system(size: 11)).foregroundStyle(Brand.sideMuted)
        }
        .padding(18)
        .frame(width: 190)
        .frame(maxHeight: .infinity)
        .background(Brand.sidebar)
    }
}

struct StepRow: View {
    let index: Int
    let title: String
    let done: Bool
    let current: Bool
    let skipped: Bool

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().strokeBorder(color, lineWidth: 1.5)
                    .background(Circle().fill(done && !skipped ? Brand.ice : .clear))
                if done && !skipped {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Brand.navy)
                } else {
                    Text("\(index)").font(.system(size: 10, weight: .bold)).foregroundStyle(color)
                }
            }
            .frame(width: 19, height: 19)
            Text(skipped ? "\(title) (kept)" : title)
                .font(.system(size: 12.5, weight: current ? .semibold : .regular))
                .foregroundStyle(current ? .white : done ? Brand.ice : Brand.sideMuted)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(current ? Brand.cyan.opacity(0.16) : .clear))
    }

    private var color: Color { current ? Brand.cyan : done ? Brand.ice : Brand.sideMuted }
}

// MARK: - Step 1

struct CheckView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Text(state.isUpgrade ? "Upgrade SafeCore to \(state.version)" : "Install SafeCore \(state.version)")
            .font(.system(size: 22, weight: .bold))
        Text("SafeCore runs SafeSpace's on-site detection services on this Mac.")
            .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 9) {
            ForEach(state.checks) { c in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: c.info ? "info.circle.fill" : c.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(c.info ? Brand.blue : c.ok ? .green : .red)
                    Text(c.text).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 6)
        Spacer()
        HStack {
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
            Button(state.isUpgrade ? "Upgrade" : "Continue") { state.continueFromChecks() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!state.canContinue)
        }
    }
}

// MARK: - Step 2

struct EnrolView: View {
    @EnvironmentObject var state: AppState
    @State private var triedSubmit = false

    var body: some View {
        Text("Enrol this box").font(.system(size: 22, weight: .bold))
        Text("Enter the details from the SafeSpace portal. The access key is never saved on this Mac.")
            .foregroundStyle(.secondary)
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            row("Config API endpoint", TextField("https://", text: $state.endpoint))
            row("Tenant ID", TextField("", text: $state.tenantID))
            row("Box ID", TextField("", text: $state.boxID))
            row("Domain", TextField("", text: $state.domain))
            row("Access key", SecureField("", text: $state.accessKey))
        }
        .textFieldStyle(.roundedBorder)
        .padding(.top, 4)
        if triedSubmit, let first = state.formErrors.first {
            Label(first, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 12))
        }
        Spacer()
        HStack {
            Spacer()
            Button("Back") { state.screen = .check }
            Button("Install & Enrol") {
                triedSubmit = true
                if state.formErrors.isEmpty { state.startInstall() }
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
    }

    private func row<F: View>(_ label: String, _ field: F) -> some View {
        GridRow {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            field
        }
    }
}

// MARK: - Step 3

struct InstallView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Text(state.installing ? (state.isUpgrade ? "Upgrading SafeCore…" : "Installing SafeCore…")
                              : state.errorMessage == nil ? "Done" : "Installation stopped")
            .font(.system(size: 22, weight: .bold))
        ProgressView(value: state.progressFraction).tint(Brand.blue)
        VStack(alignment: .leading, spacing: 9) {
            ForEach(state.steps) { s in
                HStack(spacing: 10) {
                    Group {
                        switch s.state {
                        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        case .running: ProgressView().controlSize(.small)
                        case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 16)
                    Text(s.title).foregroundStyle(s.state == .waiting ? .secondary : .primary)
                }
            }
        }
        if let err = state.errorMessage {
            Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.system(size: 12))
        }
        if state.showLog {
            ScrollView {
                Text(state.log.isEmpty ? "No output yet." : state.log)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        }
        Spacer(minLength: 0)
        HStack {
            Button(state.showLog ? "Hide details" : "Show details") { state.showLog.toggle() }
            Spacer()
            if !state.installing && state.errorMessage != nil {
                Button("Open full log") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Library/Logs/SafeCore/installer.log")) }
                Button("Back") { state.screen = state.isUpgrade ? .check : .enrol }
                Button("Retry") { state.screen = state.isUpgrade ? .check : .enrol }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}

// MARK: - Step 4 / control panel

struct RunningView: View {
    @EnvironmentObject var state: AppState
    @State private var showRaw = false

    var body: some View {
        HStack {
            Text(headline).font(.system(size: 22, weight: .bold))
            Spacer()
            if !state.statusText.isEmpty {
                Text(state.status.allRunning ? "Live" : "Check")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Capsule().fill((state.status.allRunning ? Color.green : Color.orange).opacity(0.16)))
                    .foregroundStyle(state.status.allRunning ? Color.green : Color.orange)
            }
        }
        if let t = state.statusTime {
            Text("Status checked \(t.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary).font(.system(size: 12))
        }
        HStack(spacing: 10) {
            Tile(value: pair(state.status.servicesRunning, state.status.servicesTotal), label: "Services running")
            Tile(value: pair(state.status.models, state.status.modelsTotal), label: "Weapon models opened")
            Tile(value: pair(state.status.camerasLive, state.status.camerasConfigured), label: "Cameras live / configured")
        }
        if state.status.servicesStarting > 0 {
            Text("\(state.status.servicesStarting) service(s) still starting. Press Refresh in a minute.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        if !state.status.daemonsDown.isEmpty {
            Label("Stopped: \(state.status.daemonsDown.joined(separator: ", ")). Press Start.", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(.orange)
        }
        if let err = state.errorMessage {
            Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.system(size: 12))
        }
        if showRaw {
            ScrollView {
                Text(state.statusText.isEmpty ? "No status yet." : state.statusText)
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        }
        Spacer(minLength: 0)
        HStack {
            Button(showRaw ? "Hide details" : "Show details") { showRaw.toggle() }
            if state.busy { ProgressView().controlSize(.small).padding(.leading, 6) }
            Spacer()
            Button("Refresh") { Task { await state.refreshStatus() } }
            Button("Start") { Task { await state.control("start") } }
            Button("Restart") { Task { await state.control("restart") } }
            Button("Stop", role: .destructive) { state.confirmStop = true }
        }
        .disabled(state.busy)
        .confirmationDialog("Stop SafeCore?", isPresented: $state.confirmStop) {
            Button("Stop everything", role: .destructive) { Task { await state.control("stop") } }
        } message: {
            Text("This stops all services, safecored and the database. Nothing restarts until you press Start or the Mac reboots.")
        }
    }

    private var headline: String {
        if state.statusText.isEmpty { return "SafeCore" }
        return state.status.allRunning ? "SafeCore is running" : "SafeCore status"
    }

    private func pair(_ a: Int?, _ b: Int?) -> String {
        guard let a else { return "—" }
        return b.map { "\(a) / \($0)" } ?? "\(a)"
    }
}

struct Tile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .bold)).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor)))
    }
}
