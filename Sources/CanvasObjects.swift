import SwiftUI

struct CanvasObject {
  let clip: Clip
  let path: CGPath
  let transform: CGAffineTransform
  let moveScale: CGFloat
  var bounds: CGRect {
    var transform = self.transform
    return path.copy(using: &transform)?.boundingBoxOfPath ?? .zero
  }

  init(clip: Clip, frame: Int, canvas: CGSize, mediaSize: CGSize?, style: CaptionStyle?) {
    self.clip = clip
    if clip.kind.isRegion {
      let box = clip.shape.fit(clip.region, in: canvas).applying(
        CGAffineTransform(scaleX: canvas.width, y: canvas.height))
      path = clip.shape.path(box)
      transform = .identity
      moveScale = 1
      return
    }
    let layout = clip.kind == .video ? VisualGeometry(clip: clip, canvas: canvas,
      aspect: mediaSize.map { $0.width / $0.height } ?? canvas.width / canvas.height) : nil
    let placement = clip.placement(at: frame, canvas: canvas, geometry: layout)
    if let layout {
      path = (clip.pictureInset?.shape ?? .rectangle).path(layout.visible)
    } else {
      let box = artworkBounds(clip, size: canvas, style: style)
      let visible = CGRect(x: box.minX, y: -box.maxY, width: box.width, height: box.height)
      path = clip.kind == .ellipse ? CGPath(ellipseIn: visible, transform: nil)
        : CGPath(rect: visible, transform: nil)
    }
    transform = CGAffineTransform(translationX: placement.center.x, y: placement.center.y)
      .rotated(by: clip.angle * .pi / 180).scaledBy(x: placement.scale, y: placement.scale)
    moveScale = placement.anchorsToCanvas ? placement.scale : 1
  }

  func contains(_ point: CGPoint) -> Bool {
    path.contains(point.applying(transform.inverted()))
  }
}

extension Editor {
  func canvasObjects(at frame: Int, size: CGSize) -> [CanvasObject] {
    guard !p.clips.isEmpty else { return [] }
    let active = (!busy ? (previewComposition?.instruction(at: frame) as? Slice)?.clips : nil) ?? p.clips
    let visible = active.filter { clip in
      clip.kind != .audio && (clip.start..<clip.end).contains(frame) && (clip.kind.isRegion || clip.opacity > 0)
    }
    let ordered: [Clip]
    if p.trackOrder != nil {
      let ids = Set(visible.map(\.id))
      let pinned = visible.reversed().filter { $0.kind == .caption }
      let tracks = timelineLayout.lanes.flatMap { lane in
        lane.track.clips.reversed().filter { $0.kind != .caption && ids.contains($0.id) }
      }
      ordered = pinned + tracks
    } else {
      let layers = visible.reversed()
      ordered = layers.filter { $0.kind == .caption }
        + layers.filter { $0.pictureInset != nil && $0.kind == .video }
        + layers.filter { $0.kind == .highlight }
        + layers.filter { $0.kind == .zoom }
        + layers.filter { $0.kind.isArt && !$0.kind.isRegion && $0.kind != .caption }
        + layers.filter { $0.kind == .video && $0.pictureInset == nil }
    }
    return ordered.map { clip in
      CanvasObject(clip: clip, frame: frame, canvas: size, mediaSize: clip.asset.flatMap { mediaSizes[$0] },
                   style: p.captionStyle)
    }
  }
}

struct CanvasMove {
  struct Guide: Equatable {
    let coordinate: CGFloat
    let distance: CGFloat
  }

  let item: CanvasObject
  let canvas: CGSize
  private let xTargets: [CGFloat]
  private let yTargets: [CGFloat]

  init(item: CanvasObject, canvas: CGSize, neighbors: [CanvasObject]) {
    self.item = item
    self.canvas = canvas
    let rects = [CGRect(origin: .zero, size: canvas)]
      + neighbors.filter { $0.clip.id != item.clip.id }.map(\.bounds)
    xTargets = rects.flatMap { [$0.minX, $0.midX, $0.maxX] }
    yTargets = rects.flatMap { [$0.minY, $0.midY, $0.maxY] }
  }

  func translated(by delta: CGSize) -> (clip: Clip, x: Guide?, y: Guide?) {
    let rect = item.bounds.offsetBy(dx: delta.width, dy: delta.height)
    let x = nearest([rect.minX, rect.midX, rect.maxX], targets: xTargets)
    let y = nearest([rect.minY, rect.midY, rect.maxY], targets: yTargets)
    var clip = item.clip
    if clip.kind.isRegion {
      let width = rect.width / canvas.width, height = rect.height / canvas.height
      clip.setRegion(CGRect(x: bound((rect.minX + (x?.distance ?? 0)) / canvas.width, 0, 1 - width),
                            y: bound((rect.minY + (y?.distance ?? 0)) / canvas.height, 0, 1 - height),
                            width: width, height: height))
      return (clip, x, y)
    }
    let limits = clip.kind == .video ? -4.0...5.0 : 0.0...1.0
    clip.x = bound(clip.x + (delta.width + (x?.distance ?? 0)) / (canvas.width * item.moveScale), limits.lowerBound, limits.upperBound)
    clip.y = bound(clip.y + (delta.height + (y?.distance ?? 0)) / (canvas.height * item.moveScale), limits.lowerBound, limits.upperBound)
    return (clip, x, y)
  }

  private func nearest(_ edges: [CGFloat], targets: [CGFloat]) -> Guide? {
    var best: Guide?
    var margin: CGFloat = 6
    for target in targets {
      for edge in edges where abs(target - edge) < margin {
        best = Guide(coordinate: target, distance: target - edge)
        margin = abs(target - edge)
      }
    }
    return best
  }
}

struct CanvasGuides: View {
  let x: CanvasMove.Guide?
  let y: CanvasMove.Guide?
  let canvas: CGSize
  let pixelsPerPoint: CGFloat

  var body: some View {
    ZStack(alignment: .topLeading) {
      Path { path in
        if let x {
          path.move(to: CGPoint(x: x.coordinate, y: 0))
          path.addLine(to: CGPoint(x: x.coordinate, y: canvas.height))
        }
        if let y {
          path.move(to: CGPoint(x: 0, y: y.coordinate))
          path.addLine(to: CGPoint(x: canvas.width, y: y.coordinate))
        }
      }.stroke(UI.mint, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
      if let x { distance(x).position(x: bound(x.coordinate + 23, 22, canvas.width - 22), y: 16) }
      if let y { distance(y).position(x: 24, y: bound(y.coordinate - 12, 10, canvas.height - 10)) }
    }.frame(width: canvas.width, height: canvas.height).allowsHitTesting(false)
      .accessibilityHidden(true)
  }

  private func distance(_ guide: CanvasMove.Guide) -> some View {
    Text("\(Int((abs(guide.distance) * pixelsPerPoint).rounded())) px")
      .font(.caption2.monospacedDigit()).foregroundStyle(UI.mint)
      .padding(3).background(UI.deep, in: RoundedRectangle(cornerRadius: 3))
  }
}

// Observe clicks without taking drag or resize events away from the handles.
struct CanvasPickSurface: NSViewRepresentable {
  let editor: Editor
  let visible: CGRect

  func makeNSView(context: Context) -> Surface { let view = Surface(); view.input = self; return view }
  func updateNSView(_ view: Surface, context: Context) { view.input = self }

  final class Surface: NSView {
    var input: CanvasPickSurface?
    private var monitor: Any?
    private var press: CGPoint?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]) {
        [weak self] event in self?.handle(event) == true ? nil : event
      }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    private func handle(_ event: NSEvent) -> Bool {
      guard event.window === window, let input, !input.editor.transport.playing,
        input.editor.regionTool == nil, input.editor.cropID == nil,
        input.editor.pathDrawingID == nil, input.editor.backgroundColorPick == nil else { return false }
      let point = convert(event.locationInWindow, from: nil)
      let contained = bounds.intersection(input.visible).contains(point)
      let isMenu = event.type == .rightMouseDown
        || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
      if !isMenu, event.type == .leftMouseDown { press = contained ? point : nil; return false }
      if isMenu { press = nil }
      else {
        defer { press = nil }
        guard let press, input.editor.liveCanvas.activeID == nil,
          hypot(press.x - point.x, press.y - point.y) < 3 else { return false }
      }
      guard contained else { return false }
      let editor = input.editor
      let hits = editor.canvasObjects(at: editor.transport.frame, size: bounds.size).filter { $0.contains(point) }
      if !isMenu {
        if let first = hits.first { editor.pickCanvasClip(first.clip.id) }
        return false
      }
      guard !hits.isEmpty else { return false }
      let menu = NSMenu()
      menu.autoenablesItems = false
      for hit in hits {
        let title = editor.p.name(hit.clip).split(whereSeparator: \.isNewline).first.map(String.init) ?? hit.clip.kind.title
        let item = NSMenuItem(title: String(title.prefix(42)), action: #selector(pick(_:)), keyEquivalent: "")
        item.representedObject = hit.clip.id as NSUUID
        item.target = self
        item.state = editor.selected == hit.clip.id ? .on : .off
        menu.addItem(item)
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.window != nil else { return }
        menu.popUp(positioning: nil, at: point, in: self)
      }
      return true
    }

    @objc private func pick(_ item: NSMenuItem) {
      guard let id = item.representedObject as? UUID, let editor = input?.editor,
        editor.p.clips.contains(where: { $0.id == id }) else { return }
      editor.pickCanvasClip(id)
    }
  }
}
