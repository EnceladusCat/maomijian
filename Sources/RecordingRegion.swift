import AppKit

/// Coordinates are local to the selected display, with the origin at its upper left.
struct RecordingRegion {
  private let screen: CGRect
  private(set) var rect: CGRect
  private var drag: Drag?

  private struct Drag {
    let point: CGPoint
    let original: CGRect
    let mode: Mode
  }

  private enum Mode {
    case move, create, resize(x: Int, y: Int)
  }

  init(size: CGSize) {
    screen = CGRect(origin: .zero, size: size)
    rect = screen.insetBy(dx: size.width * 0.15, dy: size.height * 0.15).integral
  }

  var handles: [CGPoint] {
    [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
     CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
  }

  mutating func begin(at point: CGPoint) {
    let grip: CGFloat = 10
    var mode = Mode.create
    if rect.insetBy(dx: -grip, dy: -grip).contains(point) {
      let x = abs(point.x - rect.minX) <= grip ? -1 : abs(point.x - rect.maxX) <= grip ? 1 : 0
      let y = abs(point.y - rect.minY) <= grip ? -1 : abs(point.y - rect.maxY) <= grip ? 1 : 0
      mode = x == 0 && y == 0 ? .move : .resize(x: x, y: y)
    }
    drag = Drag(point: point, original: rect, mode: mode)
  }

  mutating func update(to input: CGPoint) {
    guard let drag else { return }
    let point = CGPoint(x: bound(input.x, 0, screen.width), y: bound(input.y, 0, screen.height))
    let minWidth = min(64, screen.width)
    let minHeight = min(64, screen.height)
    let start = drag.original
    switch drag.mode {
    case .move:
      rect.origin = CGPoint(
        x: bound(start.minX + point.x - drag.point.x, 0, screen.width - start.width),
        y: bound(start.minY + point.y - drag.point.y, 0, screen.height - start.height))
    case .create:
      let new = CGRect(x: min(point.x, drag.point.x), y: min(point.y, drag.point.y),
        width: abs(point.x - drag.point.x), height: abs(point.y - drag.point.y))
      if new.width >= minWidth && new.height >= minHeight { rect = new }
    case .resize(let x, let y):
      let left = x < 0 ? min(point.x, start.maxX - minWidth) : start.minX
      let right = x > 0 ? max(point.x, start.minX + minWidth) : start.maxX
      let top = y < 0 ? min(point.y, start.maxY - minHeight) : start.minY
      let bottom = y > 0 ? max(point.y, start.minY + minHeight) : start.maxY
      rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
    rect = rect.integral.intersection(screen)
  }

  mutating func end() { drag = nil }
}

final class RecordingRegionView: NSView {
  private(set) var region: RecordingRegion
  var useRegion = false { didSet { needsDisplay = true } }

  init(size: CGSize) {
    region = RecordingRegion(size: size)
    super.init(frame: CGRect(origin: .zero, size: size))
    setAccessibilityLabel(L("拖动框选录屏区域"))
  }
  required init?(coder: NSCoder) { fatalError() }
  override var isFlipped: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let accent = NSColor(srgbRed: 0.67, green: 0.65, blue: 1, alpha: 1)
    let rect = useRegion ? region.rect : bounds.insetBy(dx: 2, dy: 2)
    if useRegion {
      let shade = NSBezierPath(rect: bounds)
      shade.appendRect(rect)
      shade.windingRule = .evenOdd
      NSColor.black.withAlphaComponent(0.45).setFill()
      shade.fill()
    }
    accent.setStroke()
    let outline = NSBezierPath(rect: rect)
    outline.lineWidth = useRegion ? 2 : 3
    outline.stroke()
    if useRegion {
      accent.setFill()
      for point in region.handles {
        NSBezierPath(roundedRect: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8),
          xRadius: 2, yRadius: 2).fill()
      }
    }
  }

  override func mouseDown(with event: NSEvent) {
    region.begin(at: convert(event.locationInWindow, from: nil))
  }

  override func mouseDragged(with event: NSEvent) {
    region.update(to: convert(event.locationInWindow, from: nil))
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) { region.end() }
}
