import AppKit
import SwiftUI
import TankardAppModel

// 0.8.10 (macOS 26): with the keyboard focus on the toolbar's View picker
// (Tab, Full Keyboard Access: the ring was on it), its accessibility element
// was the focused one but had no AXFocused attribute, and UI scripting
// (System Events) found no focused element at all; macOS 15 was fine. On 26
// AppKit wraps each toolbar item in an element of its own that doesn't list
// the item's control among its children. Like B5 in 0.8.9 (one proper
// element), the picker on 26 is now an AppKit view that is itself the first
// responder and the accessibility element: "View, Installed, button",
// AXFocused true while it has the focus, a focus-changed notification when
// it gets it. (Refresh, a plain SwiftUI Button, already reported AXFocused
// true on 26 through the accessibility API.)

/// The View picker: the drawn segments (ThemedSegmentedPicker, without its
/// own keyboard focus) inside an AppKit view that takes the focus, the
/// arrow keys and the accessibility: "View, Installed, button", the same
/// element as B5's (press: next option; increment/decrement; each option a
/// named action).
struct ToolbarSegmentedPicker<Value: Hashable & Identifiable>: NSViewRepresentable {
    var title: String
    @Binding var selection: Value
    var options: [Value]
    var label: (Value) -> String
    var theme: Theme
    var help: String = ""

    private var segments: AnyView {
        AnyView(ThemedSegmentedPicker(title: title, selection: $selection, options: options, label: label, keyboard: false)
            .environment(\.theme, theme))
    }

    func makeNSView(context: Context) -> FocusHost {
        let host = FocusHost(content: segments)
        update(host)
        return host
    }

    func updateNSView(_ host: FocusHost, context: Context) {
        host.hosting.rootView = segments
        update(host)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FocusHost, context: Context) -> CGSize? {
        nsView.hosting.fittingSize
    }

    private func update(_ host: FocusHost) {
        let binding = $selection
        let options = options
        let label = label
        host.title = title
        host.toolTip = help.isEmpty ? nil : help
        host.valueText = label(selection)
        host.optionNames = options.map(label)
        host.step = { delta, wrap in
            if let next = SegmentedStep.move(from: binding.wrappedValue, in: options, by: delta), next != binding.wrappedValue {
                binding.wrappedValue = next
            } else if wrap, let first = options.first {
                binding.wrappedValue = first
            }
        }
        host.select = { i in if options.indices.contains(i) { binding.wrappedValue = options[i] } }
    }

    final class FocusHost: NSView {
        let hosting: NSHostingView<AnyView>
        var title = ""
        var valueText = "" {
            didSet { if oldValue != valueText { NSAccessibility.post(element: self, notification: .valueChanged) } }
        }
        var optionNames: [String] = []
        var step: (Int, Bool) -> Void = { _, _ in }
        var select: (Int) -> Void = { _ in }

        init(content: AnyView) {
            hosting = NSHostingView(rootView: content)
            super.init(frame: .zero)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
                hosting.topAnchor.constraint(equalTo: topAnchor),
                hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            focusRingType = .exterior
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var intrinsicContentSize: NSSize { hosting.fittingSize }

        // Keyboard: one stop, reached only by Tab (a click selects a
        // segment without taking the focus, as before).
        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok { NSAccessibility.post(element: self, notification: .focusedUIElementChanged) }
            return ok
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 123: step(-1, false) // ←
            case 124: step(1, false) // →
            default: super.keyDown(with: event)
            }
        }

        // The focus ring: the control's rounded track, as the SwiftUI ring was.
        override var focusRingMaskBounds: NSRect { bounds }
        override func drawFocusRingMask() {
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }

        // Accessibility: this view is the element; the drawn segments aren't.
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .button }
        override func accessibilityLabel() -> String? { title }
        override func accessibilityValue() -> Any? { valueText }
        override func accessibilityChildren() -> [Any]? { [] }
        override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }
        override func accessibilityPerformPress() -> Bool { step(1, true); return true }
        override func accessibilityPerformIncrement() -> Bool { step(1, false); return true }
        override func accessibilityPerformDecrement() -> Bool { step(-1, false); return true }
        override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
            optionNames.enumerated().map { i, name in
                NSAccessibilityCustomAction(name: name) { [weak self] in self?.select(i); return true }
            }
        }
    }
}
