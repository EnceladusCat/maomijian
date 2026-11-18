import SwiftUI

// Keep the rectangle on a native overlay while dragging. Publish a selection
// only on release so the inspector and individual tracks stay responsive.
final class MarqueeSelection {
  weak var overlay: MarqueeOverlay.Surface?
  private var origin: CGPoint?
  private var modifiers: NSEvent.ModifierFlags = []
  private var dragged = false

  func start(_ event: NSEvent) {
    cancel()
    guard let overlay else { return }
    origin = overlay.clampedPoint(for: event)
    modifiers = event.modifierFlags.intersection([.command, .shift])
  }

  func update(_ event: NSEvent) {
    guard let overlay, let origin else { return }
    let point = overlay.clampedPoint(for: event)
    guard dragged || hypot(point.x - origin.x, point.y - origin.y) >= 4 else { return }
    dragged = true
    overlay.box = CGRect(
      x: min(origin.x, point.x), y: min(origin.y, point.y),
      width: max(1, abs(origin.x - point.x)), height: max(1, abs(origin.y - point.y))
    )
    .intersection(overlay.selectionBounds)
  }

  func finish(_ event: NSEvent, click: () -> Void) {
    guard origin != nil else { return }
    update(event)
    let box = dragged ? overlay?.box : nil
    let flags = modifiers
    cancel()
    if let box { overlay?.select?(box, flags) } else if flags.isEmpty { click() }
  }

  @discardableResult func cancel() -> Bool {
    let hadGesture = origin != nil
    origin = nil
    dragged = false
    overlay?.box = nil
    return hadGesture
  }
}

struct MarqueeOverlay: NSViewRepresentable {
  let selection: MarqueeSelection
  var leftInset: CGFloat = 0, rightInset: CGFloat = 0
  let onSelect: (CGRect, NSEvent.ModifierFlags) -> Void

  func makeNSView(context: Context) -> Surface { Surface() }
  func updateNSView(_ view: Surface, context: Context) {
    selection.overlay = view
    view.leftInset = leftInset
    view.rightInset = rightInset
    view.select = onSelect
  }

  final class Surface: NSView {
    override var isFlipped: Bool { true }
    var leftInset: CGFloat = 0, rightInset: CGFloat = 0
    var select: ((CGRect, NSEvent.ModifierFlags) -> Void)?
    var box: CGRect? { didSet { if box != oldValue { needsDisplay = true } } }
    var selectionBounds: CGRect {
      CGRect(
        x: leftInset, y: 0, width: max(0, bounds.width - leftInset - rightInset),
        height: bounds.height)
    }
    func clampedPoint(for event: NSEvent) -> CGPoint {
      let point = convert(event.locationInWindow, from: nil)
      let area = selectionBounds
      return CGPoint(
        x: bound(point.x, area.minX, area.maxX), y: bound(point.y, area.minY, area.maxY))
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
      guard let box, !box.isEmpty else { return }
      let accent = NSColor(UI.accent)
      accent.withAlphaComponent(0.14).setFill()
      NSBezierPath(rect: box).fill()
      accent.setStroke()
      let outline = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
      outline.lineWidth = 1
      outline.stroke()
    }
  }
}

struct MarqueeBlank: NSViewRepresentable {
  let selection: MarqueeSelection
  let click: () -> Void
  func makeNSView(context: Context) -> Surface { Surface() }
  func updateNSView(_ view: Surface, context: Context) {
    view.selection = selection
    view.click = click
  }
  final class Surface: NSView {
    var selection: MarqueeSelection?
    var click: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
      window?.makeFirstResponder(self)
      selection?.start(event)
    }
    override func mouseDragged(with event: NSEvent) { selection?.update(event) }
    override func mouseUp(with event: NSEvent) { selection?.finish(event) { click?() } }
  }
}

struct MarqueeBounds<ID: Hashable>: PreferenceKey {
  static var defaultValue: [ID: CGRect] { [:] }
  static func reduce(value: inout [ID: CGRect], nextValue: () -> [ID: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

struct MarqueeTarget<ID: Hashable>: View {
  let id: ID
  let space: String
  var body: some View {
    GeometryReader { geo in
      Color.clear.preference(key: MarqueeBounds<ID>.self, value: [id: geo.frame(in: .named(space))])
    }.allowsHitTesting(false)
  }
}
