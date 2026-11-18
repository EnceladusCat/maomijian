import SwiftUI

/// Use the native menu for long lists of fonts, clips and edit points.
struct MenuField: NSViewRepresentable {
  let title: String
  let choices: [String]
  let selectedIndex: Int
  let choose: (Int) -> Void
  final class Coordinator: NSObject {
    var titles: [String] = []
    var select: ((Int) -> Void)?
    @objc func picked(_ sender: NSPopUpButton) {
      let index = sender.indexOfSelectedItem
      if titles.indices.contains(index) { select?(index) }
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSPopUpButton {
    let view = NSPopUpButton(frame: .zero, pullsDown: false)
    view.controlSize = .small
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.setAccessibilityLabel(title)
    view.target = context.coordinator
    view.action = #selector(Coordinator.picked(_:))
    return view
  }
  func updateNSView(_ view: NSPopUpButton, context: Context) {
    let coordinator = context.coordinator
    coordinator.select = choose
    if coordinator.titles != choices {
      coordinator.titles = choices
      let menu = NSMenu()
      for name in choices { menu.addItem(withTitle: name, action: nil, keyEquivalent: "") }
      view.menu = menu
    }
    if view.indexOfSelectedItem != selectedIndex, choices.indices.contains(selectedIndex) {
      view.selectItem(at: selectedIndex)
    }
  }
}
