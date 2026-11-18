import Foundation
import Observation
import TankardCore

/// 0.4 (part A): the Services tab. `brew services list --json` when the tab
/// opens (a read, off the queue), `brew services info --json <name>` for
/// the selected service, and start / stop / restart through the queue.
///
/// Only the user's own services (~/Library/LaunchAgents) are controlled.
/// One started with sudo runs as root; stopping it needs sudo, which Tankard
/// never runs, so it shows the command to run in Terminal instead.
@Observable @MainActor
public final class ServicesStore {
    public enum Phase: Equatable, Sendable {
        case idle, loading, ready
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var services: [BrewService] = []
    /// `brew services info` results by name (the detail pane's extras).
    public private(set) var info: [String: BrewService] = [:]
    public var selection: BrewService.ID?
    /// The toolbar search, on this tab: filters by name.
    public var query = ""
    /// The last action's problem (sudo, or brew's error), shown in the pane.
    public private(set) var actionError: StoreError?
    public private(set) var loadedAt: Date?

    @ObservationIgnored let client: BrewClient
    @ObservationIgnored let env: [String: String]
    /// The login name, to tell the user's services from root's.
    @ObservationIgnored public let currentUser: String

    public init(client: BrewClient, env: [String: String], currentUser: String) {
        self.client = client
        self.env = env
        self.currentUser = currentUser
    }

    public var selected: BrewService? {
        guard let selection, let s = services.first(where: { $0.id == selection }) else { return nil }
        return info[s.name].map { s.merging(info: $0) } ?? s
    }

    public var listCommand: String { BrewCommands.display(BrewServices.listArguments) }

    /// "2 services · 1 running · 1 error"
    public var summary: String {
        guard !services.isEmpty else { return String(localized: "No services") }
        var parts = [services.count == 1 ? String(localized: "\(services.count) service") : String(localized: "\(services.count) services")]
        let running = services.filter { $0.status == .started }.count
        if running > 0 { parts.append(String(localized: "\(running) running")) }
        let failed = services.filter { $0.status == .error }.count
        if failed > 0 { parts.append(failed == 1 ? String(localized: "\(failed) error") : String(localized: "\(failed) errors")) }
        return parts.joined(separator: " · ")
    }

    /// The command for an action, as the user would type it.
    public func command(_ action: ServiceAction, _ s: BrewService) -> String {
        BrewCommands.display(BrewServices.displayArguments(action, s.name))
    }

    /// What to run in Terminal instead, for a service only root can control.
    public func sudoCommand(_ action: ServiceAction, _ s: BrewService) -> String {
        "sudo " + command(action, s)
    }

    public func needsSudo(_ s: BrewService) -> Bool { s.needsSudo(currentUser: currentUser) }

    public func load() async {
        guard phase != .loading else { return }
        phase = .loading
        do {
            let r = try await client.runner.run(client.installation.brewPath, BrewServices.listArguments, environment: env)
            guard r.exitCode == 0 else {
                let text = (r.stderrString + "\n" + r.stdoutString).trimmingCharacters(in: .whitespacesAndNewlines)
                phase = .failed(text.isEmpty ? String(localized: "brew services list exited \(r.exitCode)") : text)
                return
            }
            services = try BrewServices.decode(r.stdout)
            info = [:]
            loadedAt = Date()
            if let s = selection, !services.contains(where: { $0.id == s }) { selection = nil }
            phase = .ready
        } catch {
            phase = .failed(String(describing: error))
        }
        if let s = selected { await loadInfo(s.name) }
    }

    /// `brew services info --json <name>`: plist, logs, pid, the command.
    public func loadInfo(_ name: String) async {
        guard info[name] == nil else { return }
        guard let r = try? await client.runner.run(client.installation.brewPath, BrewServices.infoArguments(name), environment: env),
              r.exitCode == 0, let row = try? BrewServices.decode(r.stdout).first else { return }
        info[name] = row
    }

    /// Start, stop or restart through the queue (`store.runQuick`), then
    /// re-read the list. A root service never reaches brew: the pane shows
    /// the sudo command instead.
    public func perform(_ action: ServiceAction, on s: BrewService, store: AppStore) async {
        actionError = nil
        if needsSudo(s) {
            actionError = Self.sudoError(action, s, command: sudoCommand(action, s))
            return
        }
        let args = BrewServices.arguments(action, s.name)
        guard let r = await store.runQuick(args) else { return }
        if r.failed {
            let sudo = Self.outputNeedsSudo(r.lines, currentUser: currentUser) ? sudoCommand(action, s) : nil
            actionError = sudo.map { Self.sudoError(action, s, command: $0) }
                ?? AppStore.quickError(verb: action.title, name: s.name, args: args, result: r)
        }
        info[s.name] = nil
        await load()
    }

    static func sudoError(_ action: ServiceAction, _ s: BrewService, command: String) -> StoreError {
        let user = s.user ?? "root"
        return StoreError(title: String(localized: "\(s.name) runs as \(user): \(action.rawValue) needs sudo"),
                   detail: String(localized: "Tankard only controls your own services and never runs sudo. Run this in Terminal:"),
                   terminalCommand: command)
    }

    /// brew's own words when a service belongs to root: "Service `x` is
    /// started as `root`. Try: sudo brew services stop x"
    /// (services/cli.rb), or sudo's prompts.
    public static func outputNeedsSudo(_ lines: [String], currentUser: String) -> Bool {
        if SudoDetector.needsSudo(lines) { return true }
        return lines.contains { l in
            (l.contains("is started as `") && !l.contains("is started as `\(currentUser)`"))
                || l.contains("sudo brew services ")
        }
    }
}

public extension AppStore {
    /// The Services tab's store, made on first use (nothing runs at launch).
    @discardableResult
    func openServices() -> ServicesStore? {
        if let services { return services }
        guard let client = try? resolvedClient(), let detection = report?.intelbrew else { return nil }
        let s = ServicesStore(client: client, env: client.environment(for: detection),
                              currentUser: client.sources.process["USER"] ?? NSUserName())
        services = s
        return s
    }
}
