import SwiftUI
import AppKit

struct CommentEditorPopover: View {
    let title: String
    @Binding var commentText: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    private var isEmpty: Bool {
        commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "text.bubble.fill")
                    .foregroundStyle(.blue)
                Text(title)
                    .font(.headline)
            }

            // Text editor with auto-focus
            FocusedTextEditor(
                text: $commentText,
                onCommandReturn: {
                    guard !isEmpty else { return }
                    onSubmit()
                }
            )
            .frame(width: 400, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )

            // Footer
            HStack(spacing: 4) {
                Text("\u{2318}\u{23CE}")
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color(nsColor: .separatorColor).opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text("to submit")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Submit") {
                    guard !isEmpty else { return }
                    onSubmit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isEmpty)
            }
        }
        .padding(14)
    }
}

/// NSTextView wrapper that reliably gains focus in popovers and handles Cmd-Return.
struct FocusedTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onCommandReturn: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = CommandReturnTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textColor = NSColor.labelColor
        textView.isEditable = true
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.delegate = context.coordinator
        textView.onCommandReturn = onCommandReturn

        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView

        // Delayed focus to work in popovers
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            textView.window?.makeFirstResponder(textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CommandReturnTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.onCommandReturn = onCommandReturn
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FocusedTextEditor

        init(_ parent: FocusedTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

class CommandReturnTextView: NSTextView {
    var onCommandReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 && event.modifierFlags.contains(.command) {
            onCommandReturn?()
            return
        }
        super.keyDown(with: event)
    }
}
