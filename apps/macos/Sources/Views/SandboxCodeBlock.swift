import AppKit
import SwiftUI

struct SandboxCodeBlock: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(.caption, design: .monospaced))
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(Color(nsColor: .controlBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .textSelection(.enabled)
  }
}
