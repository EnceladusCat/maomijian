import SwiftUI

/// Use the native menu for long lists of fonts, clips and edit points.
struct MenuField: NSViewRepresentable {
  let title: String
  let choices: [String]
  let selectedIndex: Int
  var loadChoices: (() -> [String])? = nil
  let choose: (Int) -> Void
  final class Coordinator: NSObject {
    var titles: [String] = []
    var select: ((Int) -> Void)?
    var loadChoices: (() -> [String])?
    var currentTitle: String?
    var didLoadChoices = false

    func setTitles(_ choices: [String], on button: NSPopUpButton) {
      guard titles != choices else { return }
      titles = choices
      let menu = NSMenu()
      for name in choices { menu.addItem(withTitle: name, action: nil, keyEquivalent: "") }
      button.menu = menu
    }

    @objc func willPopUp(_ notification: Notification) {
      guard !didLoadChoices, let loadChoices, let button = notification.object as? NSPopUpButton else { return }
      didLoadChoices = true
      setTitles(loadChoices(), on: button)
      if let currentTitle, titles.contains(currentTitle) {
        button.selectItem(withTitle: currentTitle)
      }
    }

    @objc func picked(_ sender: NSPopUpButton) {
      guard loadChoices == nil || didLoadChoices else { return }
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
    if loadChoices != nil {
      NotificationCenter.default.addObserver(
        context.coordinator, selector: #selector(Coordinator.willPopUp(_:)),
        name: NSPopUpButton.willPopUpNotification, object: view)
    }
    return view
  }
  func updateNSView(_ view: NSPopUpButton, context: Context) {
    let coordinator = context.coordinator
    coordinator.select = choose
    coordinator.loadChoices = loadChoices
    if loadChoices != nil {
      coordinator.currentTitle = choices.first
      if coordinator.didLoadChoices, let name = choices.first,
        coordinator.titles.contains(name)
      {
        if view.titleOfSelectedItem != name { view.selectItem(withTitle: name) }
        return
      }
      coordinator.didLoadChoices = false
    }
    coordinator.setTitles(choices, on: view)
    if view.indexOfSelectedItem != selectedIndex, choices.indices.contains(selectedIndex) {
      view.selectItem(at: selectedIndex)
    }
  }
  static func dismantleNSView(_ view: NSPopUpButton, coordinator: Coordinator) {
    NotificationCenter.default.removeObserver(coordinator, name: NSPopUpButton.willPopUpNotification, object: view)
  }
}
