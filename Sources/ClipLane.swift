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
  let laneClipIDs: () -> [UUID]
  let showAlignment: (Int?) -> Void
  @Binding var groupOffset: CGFloat

  func makeNSView(context: Context) -> Surface { Surface() }
  func updateNSView(_ view: Surface, context: Context) {
    view.editor = editor
    view.groupMove = { groupOffset = $0 }
    view.showAlignment = showAlignment
    view.laneClipIDs = laneClipIDs
    if view.layoutData != layout {
      view.layoutData = layout
      view.needsDisplay = true
    }
  }

  final class Surface: NSView, NSViewToolTipOwner {
    weak var editor: Editor?
    var layoutData: Layout?
    var groupMove: ((CGFloat) -> Void)?
    var showAlignment: ((Int?) -> Void)?
    var laneClipIDs: (() -> [UUID])?
    private var pressed: Clip?, origin: CGFloat = 0, delta: CGFloat = 0, edge = 0
    private var snap: TimelineSnap?
    private var movesSelection = false
    private var blankPress = false
    private var symbols: [Kind: NSImage] = [:]
    private static let groupIcon = NSImage(systemSymbolName: "link", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(paletteColors: [NSColor(UI.accent)]))
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
          let grouped = p.clip.groupID != nil
          let labelX = grouped ? 38.0 : 23.0
          if grouped {
            Self.groupIcon?.draw(
              in: CGRect(x: box.minX + 22, y: 9, width: 12, height: 12),
              from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
          }
          if box.width > labelX + 25 {
            let title = p.hasAudio && k == .video ? p.name + L(" · 含音频") : p.name
            (title as NSString).draw(
              in: NSRect(x: box.minX + labelX, y: 7, width: box.width - labelX - 5, height: 15),
              withAttributes: Self.label)
          }
        }
        if selected && data.selection.count == 1 && box.width > 18 {
          if let reveal = p.clip.editorial?.activeMetricReveal, reveal.offsetFrames >= 0 {
            let leading = pressed?.id == p.clip.id && edge < 0 ? full.minX - delta : full.minX
            let x = leading + Double(reveal.offsetFrames) * data.per
            if x >= box.minX && x < box.maxX {
              let y = box.maxY - 4
              let cue = NSBezierPath()
              cue.move(to: CGPoint(x: x, y: y - 3))
              cue.line(to: CGPoint(x: x + 3, y: y))
              cue.line(to: CGPoint(x: x, y: y + 3))
              cue.line(to: CGPoint(x: x - 3, y: y))
              cue.close()
              NSColor(UI.mint).setFill()
              cue.fill()
            }
          }
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
        let audio = p.hasAudio ? (p.clip.volume == 0 ? L("，已静音") : L("，含音频")) : ""
        let group = p.clip.groupID == nil ? "" : L("，已编组")
        button.setAccessibilityLabel(p.name + "  " + tc(p.clip.start) + " – " + tc(p.clip.end) + audio + group)
        button.setAccessibilityValue(d.selection.contains(p.clip.id) ? L("已选") : "")
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
    override func menu(for event: NSEvent) -> NSMenu? {
      guard let d = layoutData, let editor else { return nil }
      let point = convert(event.locationInWindow, from: nil)
      let clip = d.pieces.last(where: { rect($0.clip, d).contains(point) })?.clip
      guard clip != nil || editor.canPasteClips else { return nil }
      window?.makeFirstResponder(self)
      let menu = NSMenu()
      menu.autoenablesItems = false
      func add(_ title: String, _ action: Selector, shortcut: String = "", enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: shortcut)
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
      }
      if let clip {
        editor.selectForClipMenu(clip.id)
        add(L("剪切"), #selector(cutClips), shortcut: "x")
        add(L("复制"), #selector(copyClips), shortcut: "c")
      }
      add(L("粘贴"), #selector(pasteClips), shortcut: "v", enabled: editor.canPasteClips)
      if let clip {
        add(L("删除"), #selector(deleteClips))
        menu.addItem(.separator())
        add(L("复制属性"), #selector(copyProperties(_:)))
        menu.items.last?.representedObject = clip.id
        add(L("粘贴属性"), #selector(pasteProperties), enabled: editor.hasCopiedProperties)
        if let media = editor.p.asset(clip.asset), media.isStill {
          menu.addItem(.separator())
          add(L("高清化并替换此片段"), #selector(enhanceImage(_:)))
          menu.items.last?.representedObject = clip.id
        }
      }
      return menu
    }
    @objc private func cutClips() { editor?.cutClips() }
    @objc private func copyClips() { editor?.copyClips() }
    @objc private func pasteClips() { editor?.pasteClips() }
    @objc private func deleteClips() { editor?.remove() }
    @objc private func copyProperties(_ item: NSMenuItem) {
      if let id = item.representedObject as? UUID { editor?.copyProperties(from: id) }
    }
    @objc private func pasteProperties() { editor?.pasteProperties() }
    @objc private func enhanceImage(_ item: NSMenuItem) {
      guard let editor, let id = item.representedObject as? UUID,
        let clip = editor.p.clips.first(where: { $0.id == id }),
        let media = editor.p.asset(clip.asset) else { return }
      editor.enhanceImage(media, replacing: id)
    }

    override func mouseDown(with event: NSEvent) {
      guard let d = layoutData, let e = editor else { return }
      window?.makeFirstResponder(self)
      let point = convert(event.locationInWindow, from: nil)
      origin = point.x
      pressed = nil
      snap = nil
      movesSelection = false
      delta = 0
      edge = 0
      blankPress = false
      let flags = event.modifierFlags.intersection([.command, .shift])
      let modified = !flags.isEmpty
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
        e.pickClip(c.id, lane: flags.contains(.shift) ? laneClipIDs?() ?? [] : [], modifiers: flags)
      }
      pressed = c
      if e.selectedIDs.count == 1 && Double(c.length) * d.per > 10 {
        let left = (Double(c.start) - d.first) * d.per
        let right = left + Double(c.length) * d.per
        if abs(point.x - left) < 5 { edge = -1 } else if abs(point.x - right) < 5 { edge = 1 }
      }
      guard !modified else { return }
      let moving = edge == 0 ? e.selectedClips : [c]
      movesSelection = edge == 0 && moving.count > 1
      let ids = Set(moving.map(\.id))
      var targets = [0, e.transport.frame]
      for other in e.p.clips where !ids.contains(other.id) { targets += [other.start, other.end] }
      var anchors = edge == 0 ? [c.start, c.end] : [edge < 0 ? c.start : c.end]
      if movesSelection {
        for outer in [moving.map(\.start).min(), moving.map(\.end).max()].compactMap({ $0 })
        where !anchors.contains(outer) { anchors.append(outer) }
      }
      snap = TimelineSnap(anchors: anchors, targets: targets, limits: e.dragRange(for: c, edge: edge))
    }
    override func mouseDragged(with event: NSEvent) {
      if blankPress {
        editor?.timelineMarquee.update(event)
        return
      }
      guard let snap, let d = layoutData else { return }
      let dx = convert(event.locationInWindow, from: nil).x - origin
      guard abs(dx) >= 2 || delta != 0 else { return }
      let placement = snap.placement(for: dx / d.per, per: d.per)
      showAlignment?(placement.guide)
      let next = Double(placement.shift) * d.per
      guard next != delta else { return }
      delta = next
      if movesSelection { groupMove?(delta) }
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
        snap = nil
        delta = 0
        edge = 0
        if movesSelection { groupMove?(0) }
        movesSelection = false
        showAlignment?(nil)
        needsDisplay = true
      }
      guard let snap, let c = pressed, let d = layoutData, let e = editor else { return }
      let dx = convert(event.locationInWindow, from: nil).x - origin
      if abs(dx) < 2 {
        e.selected = c.id
        e.seek(bound(Int((d.first + origin / d.per).rounded()), c.start, c.end - 1))
        return
      }
      e.move(c, by: snap.placement(for: dx / d.per, per: d.per).shift, edge: edge)
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
