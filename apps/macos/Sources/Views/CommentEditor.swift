import SwiftUI

struct CommentEditorPopover: View {
    let title: String
    @Binding var commentText: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    private var isEmpty: Bool {
        commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            TextEditor(text: $commentText)
                .font(.system(.body, design: .monospaced))
                .frame(width: 380, height: 100)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

            HStack {
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
        .padding(16)
    }
}
