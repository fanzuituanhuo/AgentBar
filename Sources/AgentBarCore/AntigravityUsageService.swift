import Darwin
import Foundation

public enum AntigravityUsageService {
    public static var executable: URL? {
        let home = NSHomeDirectory()
        let paths = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        return (["\(home)/.gemini/bin", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] + paths)
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("agy") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static func fetch(executable: URL, includePlan: Bool) async -> (quotas: [QuotaWindowReading], plan: String?) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: query(executable: executable, includePlan: includePlan))
            }
        }
    }

    private static func query(executable: URL, includePlan: Bool) -> ([QuotaWindowReading], String?) {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("AgentBar-agy-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            return ([], nil)
        }
        defer { try? fm.removeItem(at: directory) }
        let output = directory.appendingPathComponent("stdout")
        // Older versions could interpret /usage as an agent prompt in print mode.
        guard let version = runPrint(executable, ["--version"], directory: directory, output: output, timeout: 4),
              supportsUsage(version) else { return ([], nil) }
        let usage = runPrint(executable, [
            "--log-file", directory.appendingPathComponent("usage.log").path,
            "--print-timeout", "12s", "--output-format", "json", "-p", "/usage"
        ], directory: directory, output: output, timeout: 16)
        let quotas = usage.map(parseQuotas) ?? []
        let plan = includePlan && !quotas.isEmpty ? queryPlan(executable, directory: directory) : nil
        return (quotas, plan)
    }

    static func supportsUsage(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8),
              let version = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-").first else { return false }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
        return parts.count == 3 && !parts.lexicographicallyPrecedes([1, 1, 11])
    }

    static func parseQuotas(_ data: Data) -> [QuotaWindowReading] {
        guard let payload = try? JSONDecoder().decode(UsageResponse.self, from: data),
              payload.status == "SUCCESS", payload.command.name == "usage" else { return [] }
        let dateFormat = ISO8601DateFormatter()
        let fractionalFormat = ISO8601DateFormatter()
        fractionalFormat.formatOptions.insert(.withFractionalSeconds)
        return payload.command.data.groups.flatMap { group in
            group.buckets.compactMap { bucket in
                guard bucket.disabled != true, let fraction = bucket.remaining_fraction,
                      (0...1).contains(fraction) else { return nil }
                let window: String
                switch bucket.window {
                case "weekly": window = "周额度"
                case "5h": window = "5h 窗口"
                default: window = bucket.name
                }
                let reset = bucket.reset_time.flatMap { dateFormat.date(from: $0) ?? fractionalFormat.date(from: $0) }
                return QuotaWindowReading(
                    label: "\(group.name) · \(window)",
                    usedPercent: (1 - fraction) * 100,
                    resetsAt: reset
                )
            }
        }
    }

    private struct UsageResponse: Decodable {
        struct Command: Decodable {
            struct Payload: Decodable {
                struct Group: Decodable {
                    struct Bucket: Decodable {
                        let name: String
                        let window: String?
                        let remaining_fraction: Double?
                        let reset_time: String?
                        let disabled: Bool?
                    }

                    let name: String
                    let buckets: [Bucket]
                }

                let groups: [Group]
            }

            let name: String
            let data: Payload
        }

        let status: String
        let command: Command
    }

    private static func runPrint(
        _ executable: URL, _ arguments: [String], directory: URL, output: URL, timeout: TimeInterval
    ) -> Data? {
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let writer = try? FileHandle(forWritingTo: output) else { return nil }
        defer { try? writer.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = writer
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        waitForExit(process, timeout: timeout)
        guard process.terminationStatus == 0,
              let reader = try? FileHandle(forReadingFrom: output) else { return nil }
        defer { try? reader.close() }
        return try? reader.read(upToCount: 256 * 1024)
    }

    private static func queryPlan(_ executable: URL, directory: URL) -> String? {
        let output = directory.appendingPathComponent("tier")
        let temporary = output.appendingPathExtension("tmp")
        func quoted(_ url: URL) -> String {
            "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        // The CLI passes session metadata to the status line on stdin. Save only the plan label.
        let command = "/usr/bin/plutil -extract plan_tier raw -o - - 2>/dev/null > \(quoted(temporary)) && /bin/mv -f \(quoted(temporary)) \(quoted(output))"
        let options = ["statusLine": ["type": "command", "command": command]]
        guard let json = try? JSONEncoder().encode(options) else { return nil }

        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        var size = winsize(ws_row: 24, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&masterFD, &slaveFD, nil, nil, &size) == 0 else { return nil }
        let master = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        let slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        master.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        defer {
            master.readabilityHandler = nil
            try? master.close()
            try? slave.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "--settings", String(decoding: json, as: UTF8.self),
            "--log-file", directory.appendingPathComponent("plan.log").path
        ]
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        process.environment = environment
        process.standardInput = slave
        process.standardOutput = slave
        process.standardError = slave
        guard (try? process.run()) != nil else { return nil }
        waitForExit(process, timeout: 12) { FileManager.default.fileExists(atPath: output.path) }
        guard let text = try? String(contentsOf: output, encoding: .utf8) else { return nil }
        let plan = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !plan.isEmpty && plan.count <= 64 && !plan.contains(where: \.isNewline) ? plan : nil
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval, stop: () -> Bool = { false }) {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline && !stop() {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            let grace = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
    }
}
