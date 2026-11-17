import Foundation

/// 0.4: one row of `brew services list --json`, with the extra fields
/// `brew services info --json <name>` adds when Tankard has asked for them.
/// Shapes from brew 7.0.14 (`Library/Homebrew/services/formula_wrapper.rb`
/// `to_hash`, and `list`'s JSON_FIELDS: name, status, user, file, exit_code),
/// checked against real output on the arm64 Mac and the Intel VM.
public struct BrewService: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    public var status: ServiceStatus
    /// Who it runs as when loaded ("root" when started with sudo); nil when not loaded.
    public var user: String?
    /// The plist: in ~/Library/LaunchAgents (or /Library/LaunchDaemons) when
    /// registered, otherwise the one the formula ships.
    public var file: String?
    public var exitCode: Int?

    // `brew services info --json` only.
    public var serviceName: String?
    public var running: Bool?
    public var loaded: Bool?
    public var pid: Int?
    public var registered: Bool?
    public var command: String?
    public var logPath: String?
    public var errorLogPath: String?
    public var schedulable: Bool?

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, status, user, file, running, loaded, pid, registered, command, schedulable
        case exitCode = "exit_code"
        case serviceName = "service_name"
        case logPath = "log_path"
        case errorLogPath = "error_log_path"
    }

    public init(name: String, status: ServiceStatus, user: String? = nil, file: String? = nil, exitCode: Int? = nil) {
        self.name = name
        self.status = status
        self.user = user
        self.file = file
        self.exitCode = exitCode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        status = ServiceStatus(rawValue: (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "unknown")
        user = try? c.decodeIfPresent(String.self, forKey: .user)
        file = try? c.decodeIfPresent(String.self, forKey: .file)
        exitCode = try? c.decodeIfPresent(Int.self, forKey: .exitCode)
        serviceName = try? c.decodeIfPresent(String.self, forKey: .serviceName)
        running = try? c.decodeIfPresent(Bool.self, forKey: .running)
        loaded = try? c.decodeIfPresent(Bool.self, forKey: .loaded)
        pid = try? c.decodeIfPresent(Int.self, forKey: .pid)
        registered = try? c.decodeIfPresent(Bool.self, forKey: .registered)
        command = try? c.decodeIfPresent(String.self, forKey: .command)
        logPath = try? c.decodeIfPresent(String.self, forKey: .logPath)
        errorLogPath = try? c.decodeIfPresent(String.self, forKey: .errorLogPath)
        schedulable = try? c.decodeIfPresent(Bool.self, forKey: .schedulable)
    }

    /// The info fields from `brew services info --json` laid over this row.
    public func merging(info: BrewService) -> BrewService {
        var s = info
        s.name = name
        return s
    }

    /// Runs as someone else (root, after `sudo brew services start`), or its
    /// plist is a system LaunchDaemon: stopping or restarting it needs sudo,
    /// which Tankard never runs.
    public func needsSudo(currentUser: String) -> Bool {
        if let user, !user.isEmpty, user != currentUser { return true }
        if let file, file.hasPrefix("/Library/LaunchDaemons/") { return true }
        return false
    }
}

/// brew's status symbols (`status_symbol`): started, scheduled, stopped,
/// error, unknown, other, none.
public enum ServiceStatus: Equatable, Sendable, Hashable {
    case started, scheduled, stopped, error, unknown, other, none
    case unrecognized(String)

    public init(rawValue: String) {
        switch rawValue {
        case "started": self = .started
        case "scheduled": self = .scheduled
        case "stopped": self = .stopped
        case "error": self = .error
        case "unknown": self = .unknown
        case "other": self = .other
        case "none": self = .none
        default: self = .unrecognized(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .started: return "started"
        case .scheduled: return "scheduled"
        case .stopped: return "stopped"
        case .error: return "error"
        case .unknown: return "unknown"
        case .other: return "other"
        case .none: return "none"
        case .unrecognized(let s): return s
        }
    }
}

/// `brew services` subcommands Tankard runs. start, stop and restart
/// change launchd state, so they go through the queue; list and info are
/// reads.
public enum ServiceAction: String, Sendable, CaseIterable, Identifiable {
    case start, stop, restart
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .start: return String(localized: "Start")
        case .stop: return String(localized: "Stop")
        case .restart: return String(localized: "Restart")
        }
    }
}

public enum BrewServices {
    public static let listArguments = ["services", "list", "--json"]

    // `--` ends the options, so a name can never be read as one. brew's
    // CLI parser (cli/parser.rb, split_non_options) takes everything after
    // `--` as named arguments; checked with `brew services info --json -- php`
    // on brew 7.0.14.

    public static func infoArguments(_ name: String) -> [String] {
        ["services", "info", "--json", "--", name]
    }

    public static func arguments(_ action: ServiceAction, _ name: String) -> [String] {
        ["services", action.rawValue, "--", name]
    }

    /// `brew services list --json` (brew prints `[]` when there are none,
    /// and nothing at all from `info --all` then).
    public static func decode(_ data: Data) throws -> [BrewService] {
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        return try JSONDecoder().decode([BrewService].self, from: Data(trimmed.utf8))
    }

    /// Which buttons a service gets. Not loaded: Start. Anything loaded
    /// (running, scheduled, exited, failed): Restart, and Stop, which also
    /// unregisters it from launching at login.
    public static func actions(for s: BrewService) -> [ServiceAction] {
        switch s.status {
        case .none: return [.start]
        case .started, .scheduled, .stopped, .error, .unknown, .other: return [.stop, .restart]
        case .unrecognized: return [.start, .stop, .restart]
        }
    }
}
