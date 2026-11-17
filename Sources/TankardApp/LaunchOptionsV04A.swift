import Foundation
import SwiftUI
import TankardAppModel
import TankardCore

// v0.4 (part A) launch switches, for screenshots and testing. Read from the
// environment here so LaunchOptions itself barely changes:
//
//   TANKARD_FILTER=pinned|leaves     the Installed filter (any mode)
//   TANKARD_TAB=services             open on Services (any mode; reads only)
//   TANKARD_SERVICE_SELECT=<name>    select a service
//   TANKARD_TREE=all                 open every dependency-tree row
//   TANKARD_DEMO_PINNED=a,b          demo only: these start pinned
//   TANKARD_DEMO_MANAGE=revert|uninstall   demo only: open that sheet
//   TANKARD_DEMO_TYPED=<word>        demo only: pre-type the confirmation

enum V04ALaunch {
    static var env: [String: String] { ProcessInfo.processInfo.environment }

    static func demoPinned(_ env: [String: String] = env) -> Set<String> {
        Set((env["TANKARD_DEMO_PINNED"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    static func filter(_ env: [String: String] = env) -> PackageFilter? {
        switch env["TANKARD_FILTER"]?.lowercased() {
        case "pinned": return .pinned
        case "leaves", "requested": return .leaves
        default: return nil
        }
    }
}

@MainActor
func applyV04ALaunchOptions(store: AppStore, options: LaunchOptions) async {
    let env = V04ALaunch.env
    if let f = V04ALaunch.filter(env) { store.filter = f }
    if options.demo != nil, let k = env["TANKARD_DEMO_MANAGE"].flatMap(HomebrewManagement.Kind.init(rawValue:)) {
        store.requestManagement(k)
    }
    if env["TANKARD_TAB"]?.lowercased() == "services" {
        store.tab = .services
        guard let s = store.openServices() else { return }
        await s.load()
        if let name = env["TANKARD_SERVICE_SELECT"], s.services.contains(where: { $0.name == name }) {
            s.selection = name
            await s.loadInfo(name)
        }
    }
}
