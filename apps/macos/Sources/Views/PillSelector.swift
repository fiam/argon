import SwiftUI

struct PillSelector<Item: Identifiable & Equatable>: View {
  let items: [Item]
  @Binding var selection: Item
  let title: (Item) -> String

  var body: some View {
    HStack(spacing: 4) {
      ForEach(items) { item in
        Button {
          selection = item
        } label: {
          Text(title(item))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(selection == item ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
              Capsule()
                .fill(selection == item ? Color.accentColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
      }
    }
    .padding(4)
    .background(Color(nsColor: .controlBackgroundColor))
    .clipShape(Capsule())
    .overlay(
      Capsule()
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    )
  }
}
