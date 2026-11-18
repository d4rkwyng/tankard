import Foundation
import TankardCore

/// 0.8.6: the icon marks at the end of a package row, one cluster in this
/// order: updates itself, needs the password, Electron app. (Before 0.8.6
/// the "updates itself" arrows sat after the name, apart from the lock;
/// Derek asked for them together.) Labelled badges such as "pinned" and
/// "dep" stay after the name.
public enum RowMark: String, CaseIterable, Sendable, Identifiable {
    case updatesItself, password, electron
    public var id: String { rawValue }

    /// The marks `p` shows, in the fixed order.
    public static func marks(_ p: Package, isElectron: Bool) -> [RowMark] {
        allCases.filter { m in
            switch m {
            case .updatesItself: return p.selfUpdates
            case .password: return AdminPassword.required(p)
            case .electron: return isElectron && p.kind == .cask
            }
        }
    }
}
