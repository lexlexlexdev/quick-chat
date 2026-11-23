import AppKit
import Carbon
import SwiftUI

/// Handles Return before TextEditor consumes it, without replacing the native editor.
struct ComposerReturnKeys: NSViewRepresentable {
    let focused: Bool
    let send: () -> Void

    func makeNSView(context: Context) -> KeyScope {
        KeyScope(frame: .zero)
    }

    func updateNSView(_ view: KeyScope, context: Context) {
        view.focused = focused
        view.send = send
    }

    final class KeyScope: NSView {
        var focused = false
        var send: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            // Preserve native input-method confirmation and key handling elsewhere.
            guard focused, event.window === window,
                  let editor = window?.firstResponder as? NSTextView, !editor.hasMarkedText(),
                  event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) else { return event }

            let modifiers = event.modifierFlags.intersection([.shift, .command, .control, .option])
            switch modifiers {
            case []:
                if !event.isARepeat { send?() }
            case .shift:
                editor.insertNewline(nil)
            default:
                return event
            }
            return nil
        }
    }
}
