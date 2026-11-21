import SwiftUI

struct BackgroundColorPick {
  let token = UUID()
  let clipID: UUID
  let filterIndex: Int
  let frame: Int
  var image: CGImage?
}

struct BackgroundColorPickSurface: NSViewRepresentable {
  let pick: (CGPoint) -> Void

  func makeNSView(context: Context) -> Surface { Surface() }
  func updateNSView(_ view: Surface, context: Context) { view.pick = pick }

  final class Surface: NSView {
    var pick: ((CGPoint) -> Void)?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
      super.resetCursorRects()
      addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
      let point = convert(event.locationInWindow, from: nil)
      guard bounds.contains(point) else { return }
      pick?(CGPoint(x: point.x / bounds.width, y: point.y / bounds.height))
    }
  }
}
