import Foundation

enum PrivilegedError: LocalizedError {
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Administrator access was cancelled."
        case .failed(let message): return message
        }
    }
}

/// Runs the bundled helper script as root through the standard macOS administrator prompt.
enum Privileged {
    static let prompt = "SafeCore needs administrator access to install and control its services."

    static var helperPath: String {
        Bundle.main.path(forResource: "safecore-helper", ofType: "sh") ?? ""
    }

    /// Single-quotes a value for /bin/sh.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs `safecore-helper.sh <args>` as root and returns its output.
    /// The command goes to osascript as an argument, so nothing needs escaping inside AppleScript.
    static func runHelper(_ args: [String], env: [String: String] = [:]) async throws -> String {
        let envPart = env.map { "\($0.key)=\(quote($0.value))" }.joined(separator: " ")
        let command = (envPart.isEmpty ? "" : envPart + " ") + "/bin/bash " + quote(helperPath) + " " + args.map(quote).joined(separator: " ")

        return try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = [
                "-e", "on run argv",
                "-e", "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges",
                "-e", "end run",
                command, prompt,
            ]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.terminationHandler = { proc in
                let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if proc.terminationStatus == 0 {
                    cont.resume(returning: o.replacingOccurrences(of: "\r", with: "\n"))
                } else if e.contains("-128") {
                    cont.resume(throwing: PrivilegedError.cancelled)
                } else {
                    cont.resume(throwing: PrivilegedError.failed(e.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
