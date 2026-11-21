import SwiftUI

struct SettingsDisclosureStyle: DisclosureGroupStyle {
  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        configuration.isExpanded.toggle()
      } label: {
        HStack(spacing: 7) {
          Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(UI.muted)
            .frame(width: 12)
            .accessibilityHidden(true)
          configuration.label
        }
        .frame(maxWidth: .infinity, minHeight: 25, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(configuration.isExpanded ? L("已展开") : L("已折叠"))
      if configuration.isExpanded { configuration.content }
    }
  }
}
