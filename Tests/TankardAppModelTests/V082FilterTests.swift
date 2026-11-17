import Foundation
import Testing
import TankardCore
@testable import TankardAppModel

// 0.8.2: which filters the bar and the More menu show, in what order, and
// "Requested only" renamed "Installed by you".

@MainActor
struct V082FilterBarTests {
    private func counts(_ d: [PackageFilter: Int]) -> (PackageFilter) -> Int { { d[$0] ?? 0 } }

    @Test func order() {
        #expect(PackageFilter.segmented == [.all, .upgrades, .bottleAvailable, .source, .newer])
        #expect(PackageFilter.more == [.vulnerable, .pinned, .leaves, .hasNotes, .deprecated])
        #expect(Set(PackageFilter.segmented + PackageFilter.more) == Set(PackageFilter.allCases))
    }

    /// All and Upgrades always; the others only with a count above 0.
    @Test func zeroCountSegmentsAreHidden() {
        let none = PackageFilter.visibleSegmented(selected: .all, count: counts([:]))
        #expect(none == [.all, .upgrades])
        let some = PackageFilter.visibleSegmented(selected: .all, count: counts([.all: 9, .source: 2]))
        #expect(some == [.all, .upgrades, .source])
        let every = PackageFilter.visibleSegmented(selected: .all,
                                                   count: counts([.all: 9, .upgrades: 1, .bottleAvailable: 1, .source: 1, .newer: 1]))
        #expect(every == PackageFilter.segmented)
    }

    /// The selected segment stays at 0 (the bar doesn't jump under the
    /// mouse) and goes once another filter is chosen.
    @Test func selectedSegmentStaysAtZero() {
        let c = counts([.all: 9, .newer: 1])
        #expect(PackageFilter.visibleSegmented(selected: .bottleAvailable, count: c) == [.all, .upgrades, .bottleAvailable, .newer])
        #expect(PackageFilter.visibleSegmented(selected: .all, count: c) == [.all, .upgrades, .newer])
        // A More filter selected keeps nothing extra in the bar.
        #expect(PackageFilter.visibleSegmented(selected: .pinned, count: c) == [.all, .upgrades, .newer])
    }

    /// Every More item has its count; 0 is disabled unless selected.
    @Test func moreItems() {
        let c = counts([.vulnerable: 2, .leaves: 5])
        let items = PackageFilter.moreItems(selected: .all, count: c)
        #expect(items.map(\.filter) == PackageFilter.more)
        #expect(items.map(\.count) == [2, 0, 5, 0, 0])
        #expect(items.map(\.isEnabled) == [true, false, true, false, false])
        let selected = PackageFilter.moreItems(selected: .hasNotes, count: c)
        #expect(selected.first { $0.filter == .hasNotes }?.isEnabled == true)
        #expect(selected.first { $0.filter == .pinned }?.isEnabled == false)
    }

    @Test func installedByYouWording() {
        #expect(PackageFilter.leaves.title == "Installed by you")
        #expect(PackageFilter.leaves.help == "Packages you installed yourself, not ones pulled in as dependencies")
        #expect(PackageFilter.all.help == nil)
    }

    /// The store's lists follow the real counts and the selection.
    @Test func storeFollowsCountsAndSelection() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        await store.start()
        let expected = PackageFilter.segmented.filter { [.all, .upgrades].contains($0) || store.count($0) > 0 }
        #expect(store.visibleSegmentedFilters == expected)
        // The Intelbrew demo has a bottle to replace a source build with (vim).
        #expect(store.count(.bottleAvailable) > 0)
        #expect(store.visibleSegmentedFilters.contains(.bottleAvailable))
        #expect(store.moreFilterItems.map(\.count) == PackageFilter.more.map(store.count))

        // The same Mac after its source builds were reinstalled from
        // bottles (TANKARD_DEMO_REPLACED): Bottle available is hidden at 0...
        let eligible = Set(store.packages.filter { PackageFilter.bottleAvailable.includes($0) }.map(\.name))
        let replaced = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0, replaced: eligible), settings: testSettings())
        await replaced.start()
        #expect(replaced.count(.bottleAvailable) == 0)
        #expect(!replaced.visibleSegmentedFilters.contains(.bottleAvailable))
        #expect(replaced.visibleSegmentedFilters.first == .all)
        // ...shown while selected (TANKARD_FILTER=bottle), gone after.
        replaced.filter = .bottleAvailable
        #expect(replaced.visibleSegmentedFilters.contains(.bottleAvailable))
        replaced.filter = .all
        #expect(!replaced.visibleSegmentedFilters.contains(.bottleAvailable))
    }

    /// A disabled (0) More item can't be the reason a selection is lost:
    /// selecting one through the picker still works (the 0.6.1 binding),
    /// and it stays enabled while selected.
    @Test func selectedZeroMoreItemStaysEnabled() async throws {
        let store = AppStore(deps: Demo.dependencies(.intelbrew, pace: 0), settings: testSettings())
        await store.start()
        let zero = try #require(PackageFilter.more.first { store.count($0) == 0 }, "the demo has an empty More filter")
        #expect(store.moreFilterItems.first { $0.filter == zero }?.isEnabled == false)
        store.moreFilterSelection = zero
        #expect(store.filter == zero)
        #expect(store.moreFilterItems.first { $0.filter == zero }?.isEnabled == true)
        store.tabChanged(to: .discover)
        #expect(store.filter == .all)
    }
}
