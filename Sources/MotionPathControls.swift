import SwiftUI

struct MotionPathDrawingSurface: NSViewRepresentable {
  let finish: ([CGPoint], CGSize) -> Void

  func makeNSView(context: Context) -> Surface { Surface() }
  func updateNSView(_ view: Surface, context: Context) { view.finish = finish }

  final class Surface: NSView {
    var finish: (([CGPoint], CGSize) -> Void)?
    private var stroke: [CGPoint] = []

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
      super.resetCursorRects()
      addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
      stroke = [point(event)]
      needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
      guard let previous = stroke.last else { return }
      let next = point(event)
      guard hypot(next.x - previous.x, next.y - previous.y) >= 1.5 else { return }
      if stroke.count >= 2048 {
        stroke = stride(from: 0, to: stroke.count, by: 2).map { stroke[$0] }
      }
      stroke.append(next)
      needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
      guard !stroke.isEmpty else { return }
      let points = stroke + [point(event)]
      stroke.removeAll(keepingCapacity: true)
      needsDisplay = true
      finish?(points, bounds.size)
    }

    override func draw(_ dirtyRect: NSRect) {
      guard let first = stroke.first else { return }
      let line = NSBezierPath()
      line.move(to: first)
      line.lineCapStyle = .round
      line.lineJoinStyle = .round
      for point in stroke.dropFirst() { line.line(to: point) }
      NSColor.black.withAlphaComponent(0.72).setStroke()
      line.lineWidth = 4
      line.stroke()
      NSColor(UI.mint).setStroke()
      line.lineWidth = 2
      line.stroke()
      NSColor(UI.mint).setFill()
      NSBezierPath(ovalIn: CGRect(x: first.x - 3, y: first.y - 3, width: 6, height: 6)).fill()
    }

    private func point(_ event: NSEvent) -> CGPoint {
      let location = convert(event.locationInWindow, from: nil)
      return CGPoint(x: bound(location.x, 0, bounds.width), y: bound(location.y, 0, bounds.height))
    }
  }
}

struct MotionPathGuide: View {
  let path: MotionPath
  let clip: Clip
  let canvas: CGSize

  var body: some View {
    let points = path.guide.map { CGPoint(x: (clip.x + $0.x) * canvas.width, y: (clip.y + $0.y) * canvas.height) }
    let line = Path { $0.addLines(points) }
    ZStack(alignment: .topLeading) {
      line.stroke(.black.opacity(0.66), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
      line.stroke(UI.mint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [4, 4]))
      if let start = points.first, let finish = points.last {
        Circle().strokeBorder(UI.mint, lineWidth: 2).background(UI.deep, in: Circle())
          .frame(width: 9, height: 9).position(start)
        Circle().fill(UI.mint).overlay(Circle().strokeBorder(UI.deep, lineWidth: 1))
          .frame(width: 7, height: 7).position(finish)
      }
    }
    .frame(width: canvas.width, height: canvas.height)
    .allowsHitTesting(false).accessibilityHidden(true)
  }
}
