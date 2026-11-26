import AppKit
import SwiftUI
import TankardAppModel

// 0.9.4: the bottle banner's two window bridges, thin SwiftUI wrappers
// (no visible views) around their AppKit coordinators in TankardAppModel
// (BottleBannerBridges.swift), where they're tested.

/// Esc in the main window closes the bottle banner (BottleBannerEscapeMonitor).
struct BottleBannerEscapeKey: NSViewRepresentable {
    var bannerShown: Bool
    var dismiss: @MainActor () -> Void

    func makeCoordinator() -> BottleBannerEscapeMonitor { BottleBannerEscapeMonitor() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        let c = context.coordinator
        c.view = view
        c.bannerShown = bannerShown
        c.dismiss = dismiss
        c.attach()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.bannerShown = bannerShown
        context.coordinator.dismiss = dismiss
    }

    static func dismantleNSView(_ view: NSView, coordinator: BottleBannerEscapeMonitor) {
        coordinator.detach()
    }
}

/// VoiceOver announces the bottle banner once its window is ready
/// (BottleNoticeAnnouncementCoordinator).
struct BottleNoticeAnnouncementKey: NSViewRepresentable {
    var notice: BottleNoticeAnnouncer.Notice?

    func makeCoordinator() -> BottleNoticeAnnouncementCoordinator { BottleNoticeAnnouncementCoordinator() }

    func makeNSView(context: Context) -> WindowWatchingView {
        let view = WindowWatchingView(frame: .zero)
        context.coordinator.attach(to: view)
        context.coordinator.noticeChanged(notice)
        return view
    }

    func updateNSView(_ view: WindowWatchingView, context: Context) {
        context.coordinator.noticeChanged(notice)
    }

    static func dismantleNSView(_ view: WindowWatchingView, coordinator: BottleNoticeAnnouncementCoordinator) {
        coordinator.detach(from: view)
    }
}
