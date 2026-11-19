import Foundation

/// 0.8.8 (gauntlet 3, B8): where count strings are looked up. Counts use
/// plural variations (Localizable.stringsdict: French says "0 service",
/// English "0 services") instead of `n == 1 ? singular : plural`. In the app
/// that is the main bundle. A process without the app's tables (`swift
/// test`, `swift run`) would show the key itself ("1 casks"), so there the
/// English table from the source tree is used (debug builds only; a
/// release build never looks outside its own bundle).
public enum L10n {
    public static let bundle: Bundle = {
        #if DEBUG
        if Bundle.main.url(forResource: "Localizable", withExtension: "stringsdict") == nil {
            let en = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("TankardApp/Resources/Localizations/en.lproj")
            if let b = Bundle(url: en) { return b }
        }
        #endif
        return .main
    }()
}
