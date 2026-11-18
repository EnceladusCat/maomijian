import SwiftUI

// A lane draws its visible clips together. Switching tools or editing another
// lane no longer lays out a separate view hierarchy for every visible clip.
struct ClipLane: NSViewRepresentable {
  struct Piece: Equatable {
    let clip: Clip
    let name: String
    let hasAudio: Bool
    let waveform: AudioWaveform?
  }
  struct Layout: Equatable {
    let pieces: [Piece]
    let selection: Set<UUID>
    let first: Double, per: Double
    let groupOffset: CGFloat
  }
  static func rowHeight(_ kind: Kind) -> CGFloat { kind.isMedia ? 37 : 30 }
  static func clipBox(_ clip: Clip, first: Double, per: Double) -> CGRect {
    CGRect(
      x: (Double(clip.start) - first) * per, y: 2.5,
      width: max(2, Double(clip.length) * per), height: rowHeight(clip.kind) - 5)
  }
  let editor: Editor, layout: Layout
  @Binding var groupOffset: CGFloat

  func makeNSView(context: Context) -> Surface { Surface() }
  func updateNSView(_ view: Surface, context: Context) {
    view.editor = editor
    view.groupMove = { groupOffset = $0 }
    if view.layoutData != layout {
      view.layoutData = layout
      view.needsDisplay = true
    }
  }

  final class Surface: NSView, NSViewToolTipOwner {
    weak var editor: Editor?
    var layoutData: Layout?
    var groupMove: ((CGFloat) -> Void)?
    private var pressed: Clip?, origin: CGFloat = 0, delta: CGFloat = 0, edge = 0
    private var modified = false
    private var blankPress = false
    private var symbols: [Kind: NSImage] = [:]
    private static let label: [NSAttributedString.Key: Any] = {
      let style = NSMutableParagraphStyle()
      style.lineBreakMode = .byTruncatingTail
      return [
        .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.white, .paragraphStyle: style,
      ]
    }()
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func rect(_ c: Clip, _ layout: Layout) -> CGRect {
      var left = (Double(c.start) - layout.first) * layout.per
      var right = left + Double(c.length) * layout.per
      let primary = pressed?.id == c.id
      let shift = primary ? delta : (layout.selection.contains(c.id) ? layout.groupOffset : 0)
      if !primary || edge <= 0 { left += shift }
      if !primary || edge >= 0 { right += shift }
      return CGRect(x: left, y: 2.5, width: max(2, right - left), height: rowHeight(c.kind) - 5)
    }
    override func draw(_ dirtyRect: NSRect) {
      guard let data = layoutData else { return }
      for p in data.pieces {
        let full = rect(p.clip, data)
        let box = full.intersection(bounds)
        guard !box.isNull, box.intersects(dirtyRect) else { continue }
        let selected = data.selection.contains(p.clip.id)
        let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        let col = NSColor(UI.color(p.clip.kind))
        col.withAlphaComponent(selected ? 0.45 : 0.27).setFill()
        path.fill()
        (selected ? NSColor.white : col.withAlphaComponent(0.7)).setStroke()
        path.lineWidth = selected ? 1.5 : 1
        path.stroke()
        if let wave = p.waveform {
          drawWaveform(wave, clip: p.clip, full: full, visible: box, layout: data)
        }
        if box.width > 28 {
          let k = p.clip.kind
          if symbols[k] == nil {
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
              .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            symbols[k] = NSImage(systemSymbolName: k.icon, accessibilityDescription: nil)?
              .withSymbolConfiguration(config)
          }
          symbols[k]?.draw(
            in: NSRect(x: box.minX + 6, y: 9, width: 13, height: 12), from: .zero,
            operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
          if box.width > 48 {
            let title = p.hasAudio && k == .video ? p.name + " · 含音频" : p.name
            (title as NSString).draw(
              in: NSRect(x: box.minX + 23, y: 7, width: box.width - 28, height: 15),
              withAttributes: Self.label)
          }
        }
        if selected && box.width > 18 {
          NSColor.white.setFill()
          for x in [box.minX + 3, box.maxX - 5] {
            NSBezierPath(
              roundedRect: CGRect(x: x, y: 10, width: 2, height: 10), xRadius: 1, yRadius: 1
            ).fill()
          }
        }
      }
    }
    private func drawWaveform(
      _ wave: AudioWaveform, clip: Clip, full: CGRect, visible: CGRect, layout: Layout
    ) {
      let left = max(full.minX + 3, visible.minX)
      let right = min(full.maxX - 3, visible.maxX)
      guard right > left else { return }
      let sourceLeft = pressed?.id == clip.id && edge != 0
        ? (Double(clip.start) - layout.first) * layout.per : full.minX
      let rate = clip.effectiveRate / layout.per
      let center = full.maxY - 8
      let bars = NSBezierPath()
      for x in stride(from: left, to: right, by: 2) {
        let start = clip.sourceIn + (x - sourceLeft) * rate
        let peak = wave.peak(from: start, to: start + 2 * rate)
        let height = max(0.5, sqrt(peak) * 7)
        bars.move(to: CGPoint(x: x, y: center - height))
        bars.line(to: CGPoint(x: x, y: center + height))
      }
      NSColor(UI.color(.audio)).withAlphaComponent(clip.volume == 0 ? 0.27 : 0.82).setStroke()
      bars.lineWidth = 1
      bars.stroke()
    }
    override func setFrameSize(_ newSize: NSSize) {
      super.setFrameSize(newSize)
      removeAllToolTips()
      if !bounds.isEmpty { addToolTip(bounds, owner: self, userData: nil) }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityChildren() -> [Any]? {
      guard let d = layoutData, let editor, let window else { return [] }
      return d.pieces.compactMap { p -> Any? in
        let box = rect(p.clip, d).intersection(bounds)
        guard !box.isNull else { return nil }
        let button = AccessibleClip()
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityParent(self)
        button.setAccessibilityFrame(window.convertToScreen(convert(box, to: nil)))
        let audio = p.hasAudio ? (p.clip.volume == 0 ? "，已静音" : "，含音频") : ""
        button.setAccessibilityLabel(p.name + "  " + tc(p.clip.start) + " – " + tc(p.clip.end) + audio)
        button.setAccessibilityValue(d.selection.contains(p.clip.id) ? "已选" : "")
        button.select = { [weak editor] in
          editor?.selected = p.clip.id
          editor?.seek(p.clip.start)
        }
        return button
      }
    }
    func view(
      _ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
      point: NSPoint, userData: UnsafeMutableRawPointer?
    ) -> String {
      guard let d = layoutData, let p = d.pieces.last(where: { rect($0.clip, d).contains(point) })
      else { return "" }
      return p.name + "  " + tc(p.clip.start) + " – " + tc(p.clip.end)
    }
    override func mouseDown(with event: NSEvent) {
      guard let d = layoutData, let e = editor else { return }
      window?.makeFirstResponder(self)
      let point = convert(event.locationInWindow, from: nil)
      origin = point.x
      pressed = nil
      delta = 0
      edge = 0
      blankPress = false
      let flags = event.modifierFlags.intersection([.command, .shift])
      modified = !flags.isEmpty
      guard let c = d.pieces.last(where: { rect($0.clip, d).contains(point) })?.clip else {
        blankPress = true
        e.libraryFocus = false
        e.pause()
        e.timelineMarquee.start(event)
        return
      }
      e.pause()
      e.libraryFocus = false
      if modified || !e.selectedIDs.contains(c.id) {
        e.pickClip(c.id, lane: d.pieces.map { $0.clip.id }, modifiers: flags)
      }
      pressed = c
      if e.selectedIDs.count == 1 && Double(c.length) * d.per > 10 {
        let left = (Double(c.start) - d.first) * d.per
        let right = left + Double(c.length) * d.per
        if abs(point.x - left) < 5 { edge = -1 } else if abs(point.x - right) < 5 { edge = 1 }
      }
    }
    override func mouseDragged(with event: NSEvent) {
      if blankPress {
        editor?.timelineMarquee.update(event)
        return
      }
      guard !modified, pressed != nil, let e = editor, let d = layoutData else { return }
      delta = convert(event.locationInWindow, from: nil).x - origin
      if e.selectedIDs.count > 1 {
        delta = Double(e.groupDelta(Int((delta / d.per).rounded()))) * d.per
        groupMove?(delta)
      }
      needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
      if blankPress {
        blankPress = false
        if let editor, let layout = layoutData {
          editor.timelineMarquee.finish(event) {
            editor.selected = nil
            editor.seek(Int((layout.first + origin / layout.per).rounded()))
          }
        }
        return
      }
      defer {
        pressed = nil
        delta = 0
        edge = 0
        groupMove?(0)
        needsDisplay = true
      }
      guard !modified, let c = pressed, let d = layoutData, let e = editor else { return }
      let dx = convert(event.locationInWindow, from: nil).x - origin
      if abs(dx) < 2 {
        e.selected = c.id
        e.seek(bound(Int((d.first + origin / d.per).rounded()), c.start, c.end - 1))
        return
      }
      var shift = Int((dx / d.per).rounded())
      if edge == 0 && c.kind == .video {
        let desired = c.start + shift
        let others = e.p.clips.filter { $0.kind == .video && !e.selectedIDs.contains($0.id) }
        let snaps = others.flatMap { [$0.end, $0.start - c.length] }.filter { $0 >= 0 }
        if let snap = snaps.min(by: { abs($0 - desired) < abs($1 - desired) }),
          abs(snap - desired) <= min(15, max(1, Int(6 / d.per)))
        {
          shift = snap - c.start
        }
      }
      e.move(c, by: shift, edge: edge)
    }
  }
}

private final class AccessibleClip: NSAccessibilityElement {
  var select: (() -> Void)?
  override func accessibilityPerformPress() -> Bool {
    select?()
    return true
  }
}
