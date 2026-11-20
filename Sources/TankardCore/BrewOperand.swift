// 0.8.9 (security review F2): package names as brew's last arguments.
//
// 0.8.8 put `--` before a name that starts with "-" in BrewCommands
// (TankardAppModel). The rest of the commands Tankard builds (fetch, the
// restore plan's uninstall/link/pin, the bottle reinstall, adopt) take the
// same names, and some are built here in TankardCore, so the rule lives here.

/// Package names placed after brew's options.
public enum BrewOperand {
    /// One name: `["--", name]` when it starts with "-", so brew can't read it
    /// as an option; otherwise just `[name]` (what every real, tap-qualified
    /// name gets).
    public static func one(_ name: String) -> [String] {
        name.hasPrefix("-") ? ["--", name] : [name]
    }

    /// Several names: one `--` before all of them when any starts with "-"
    /// (after `--`, brew reads every remaining word as a name).
    public static func list(_ names: [String]) -> [String] {
        names.contains { $0.hasPrefix("-") } ? ["--"] + names : names
    }
}
