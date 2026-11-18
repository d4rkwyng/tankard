import Foundation

/// 0.8.4: what a cask puts on the Mac, from its `artifacts` stanza keys,
/// for the detail pane ("Cask: installs fonts"). A font or a command-line
/// tool used to read "installs the vendor's app".
public enum CaskContents: String, Sendable, Equatable, CaseIterable {
    case app
    case installer
    case font
    case commandLineTool
    case plugin
    /// Something else (`artifact`, `stage_only`), or nothing known.
    case other

    /// Keys that say how a cask is removed or run, not what it installs.
    static let notContents: Set<String> = ["uninstall", "zap", "preflight", "postflight",
                                           "uninstall_preflight", "uninstall_postflight", "target"]
    static let tool: Set<String> = ["binary", "manpage", "bash_completion", "zsh_completion", "fish_completion"]
    static let plugins: Set<String> = ["qlplugin", "prefpane", "screen_saver", "colorpicker", "dictionary",
                                       "service", "input_method", "internet_plugin", "audio_unit_plugin",
                                       "vst_plugin", "vst3_plugin", "mdimporter", "keyboard_layout"]

    /// The stanza keys that describe contents, in order, each once.
    static func kinds(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.filter { !notContents.contains($0) && seen.insert($0).inserted }
    }

    /// The main thing it installs: an app wins over anything else it
    /// carries (a CLI shim, a font), then an installer package, fonts,
    /// command-line tools, plug-ins. nil kinds (unknown): `.other`.
    public init(kinds: [String]?) {
        let k = Set(kinds ?? [])
        if k.contains("app") || k.contains("suite") { self = .app }
        else if k.contains("pkg") || k.contains("installer") { self = .installer }
        else if k.contains("font") { self = .font }
        else if !k.isDisjoint(with: Self.tool) { self = .commandLineTool }
        else if !k.isDisjoint(with: Self.plugins) { self = .plugin }
        else { self = .other }
    }

    public init(_ p: Package) {
        // Before 0.8.4 only apps, suites and pkg were kept: use them when
        // the kinds are missing (an older status cache).
        if p.caskArtifacts == nil, let apps = p.appPaths {
            if !apps.isEmpty || !(p.suitePaths ?? []).isEmpty { self = .app; return }
            if p.installsPkg == true { self = .installer; return }
        }
        self.init(kinds: p.caskArtifacts)
    }
}
