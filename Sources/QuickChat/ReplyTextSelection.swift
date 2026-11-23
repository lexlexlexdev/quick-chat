import AppKit
import Combine
import SwiftUI

/// Markdown renders each block separately. Use one text view for a continuous selection.
struct ReplyTextSelection: View {
    let text: String
    let source: ReplySource?
    @State private var hasStreamedText = false
    @State private var selectedReply: String?

    var body: some View {
        Button("Select text", systemImage: "text.cursor") {
            selectedReply = source?.snapshot ?? text
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .disabled(text.isEmpty && !hasStreamedText)
        .onReceive(source?.hasText ?? Just(false).eraseToAnyPublisher()) { hasStreamedText = $0 }
        .popover(isPresented: Binding(
            get: { selectedReply != nil },
            set: { if !$0 { selectedReply = nil } }
        )) {
            if let selectedReply {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reply text (Markdown)").font(.headline)
                    SelectableReply(text: selectedReply)
                }
                .padding(12)
                .frame(width: 440, height: 320)
            }
        }
    }
}

private struct SelectableReply: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let editor = scroll.documentView as? NSTextView else { return scroll }
        editor.isEditable = false
        editor.isSelectable = true
        editor.isRichText = false
        editor.drawsBackground = false
        scroll.drawsBackground = false
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 4, height: 4)
        editor.setAccessibilityLabel("Reply text")
        editor.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // The popover shows a snapshot, so streaming updates cannot reset the selection.
        if let editor = scroll.documentView as? NSTextView, editor.string != text {
            editor.string = text
        }
    }
}
