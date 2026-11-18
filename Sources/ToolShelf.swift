import Combine
import SwiftUI
import UniformTypeIdentifiers

enum ToolTab: String, CaseIterable, Identifiable {
  case media = "素材"
  case annotations = "标注"
  case transitions = "转场"
  case captions = "字幕"
  case sounds = "音效"
  case filters = "滤镜"
  var id: Self { self }
  var symbol: String {
    switch self {
    case .filters: return "camera.filters"
    case .sounds: return "waveform"
    case .captions: return "captions.bubble"
    case .media: return "film.stack"
    case .annotations: return "pencil.tip"
    case .transitions: return "rectangle.2.swap"
    }
  }
  @ViewBuilder func content(_ e: Editor) -> some View {
    switch self {
    case .filters: FilterPanel(editor: e, updates: e.panelUpdates(self))
    case .sounds: SoundPanel(e: e, shelf: e.shelf)
    case .captions: CaptionPanel(e: e, updates: e.panelUpdates(self))
    case .media: Library(e: e, updates: e.panelUpdates(self))
    case .annotations: AnnotationPanel(e: e)
    case .transitions: TransitionPanel(shelf: e.shelf, e: e, updates: e.panelUpdates(self))
    }
  }
}
/// Native tool buttons swap cached panels without invalidating the preview or timeline.
struct ToolShelf: NSViewRepresentable {
  let e: Editor

  final class Host: NSView {
    let editor: Editor
    private let rail = NSScrollView()
    private let strip = ToolStrip()
    private let div = NSView()
    private let panels = NSView()
    private var buttons = [ToolTab: ToolButton]()
    private var hosts = [ToolTab: NSView]()
    private var observation: AnyCancellable?
    private let railWidth: CGFloat = 48
    private let rowHeight: CGFloat = 43

    init(_ editor: Editor) {
      self.editor = editor
      super.init(frame: .zero)
      wantsLayer = true
      layer?.backgroundColor = NSColor(UI.panel).cgColor
      rail.drawsBackground = true
      rail.backgroundColor = NSColor(UI.deep)
      rail.hasVerticalScroller = true
      rail.scrollerStyle = .overlay
      rail.autohidesScrollers = true
      rail.setAccessibilityLabel("工具栏")
      rail.documentView = strip
      div.wantsLayer = true
      div.layer?.backgroundColor = NSColor(UI.muted).withAlphaComponent(0.16).cgColor
      addSubview(panels)
      addSubview(rail)
      addSubview(div)
      for (index, tab) in ToolTab.allCases.enumerated() {
        let button = ToolButton(tab: tab, target: self, action: #selector(selectTab(_:)))
        button.frame = CGRect(
          x: 3, y: 7 + CGFloat(index) * rowHeight, width: railWidth - 6,
          height: rowHeight - 3)
        strip.addSubview(button)
        buttons[tab] = button
      }
      observation = editor.shelf.tabs.sink { [weak self] tab in self?.display(tab) }
      for (index, tab) in [ToolTab.annotations, .transitions].enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45 + 0.4 * Double(index)) {
          [weak self] in
          guard let self, self.window != nil, self.hosts[tab] == nil else { return }
          self.host(tab).layoutSubtreeIfNeeded()
        }
      }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func layout() {
      super.layout()
      rail.frame = CGRect(x: 0, y: 0, width: railWidth, height: bounds.height)
      strip.frame = CGRect(
        x: 0, y: 0, width: railWidth,
        height: max(bounds.height, 14 + rowHeight * CGFloat(buttons.count)))
      div.frame = CGRect(x: railWidth, y: 0, width: 1, height: bounds.height)
      panels.frame = CGRect(
        x: railWidth + 1, y: 0, width: max(0, bounds.width - railWidth - 1),
        height: bounds.height)
    }
    private func host(_ tab: ToolTab) -> NSView {
      if let existing = hosts[tab] { return existing }
      let root = tab.content(editor).frame(
        maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading
      ).foregroundStyle(Color.white).preferredColorScheme(.dark)
      let view = NSHostingView(rootView: root)
      view.sizingOptions = []
      view.frame = panels.bounds
      view.autoresizingMask = [.width, .height]
      view.isHidden = true
      panels.addSubview(view)
      hosts[tab] = view
      return view
    }
    private func display(_ tab: ToolTab) {
      let view = host(tab)
      for (key, panel) in hosts where key != tab && !panel.isHidden { panel.isHidden = true }
      view.isHidden = false
      for (key, button) in buttons { button.markSelected(key == tab) }
      if let button = buttons[tab] { strip.scrollToVisible(button.frame) }
    }
    @objc private func selectTab(_ sender: ToolButton) {
      editor.openTab(sender.tab)
    }
  }
  func makeNSView(context: Context) -> Host { Host(e) }
  func updateNSView(_ view: Host, context: Context) {}
}
private final class ToolStrip: NSView {
  override var isFlipped: Bool { true }
}
private final class ToolButton: NSButton {
  let tab: ToolTab
  private let mark = CALayer()
  private var active = false

  init(tab: ToolTab, target: AnyObject, action: Selector) {
    self.tab = tab
    super.init(frame: .zero)
    self.target = target
    self.action = action
    isBordered = false
    imagePosition = .imageAbove
    image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
    toolTip = tab.rawValue + "面板"
    setAccessibilityLabel(tab.rawValue)
    setButtonType(.momentaryChange)
    focusRingType = .exterior
    wantsLayer = true
    layer?.cornerRadius = 5
    mark.cornerRadius = 1
    mark.backgroundColor = NSColor(UI.accent).cgColor
    layer?.addSublayer(mark)
    updateStyle()
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    mark.frame = CGRect(x: 0, y: (bounds.height - 18) / 2, width: 2, height: 18)
  }
  func markSelected(_ next: Bool) {
    guard next != active else { return }
    active = next
    updateStyle()
  }
  private func updateStyle() {
    let color = NSColor(active ? UI.accent : UI.muted)
    contentTintColor = color
    attributedTitle = NSAttributedString(
      string: tab.rawValue,
      attributes: [
        .font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: color,
      ])
    layer?.backgroundColor = active ? color.withAlphaComponent(0.13).cgColor : nil
    mark.isHidden = !active
    setAccessibilityValue(active ? "已选" : nil)
  }
}
struct DropBand: Equatable {
  let rect: CGRect, first: Double, per: Double, joins: Set<UUID>, clips: Set<UUID>
}
struct DropBandKey: PreferenceKey {
  static var defaultValue: [DropBand] { [] }
  static func reduce(value: inout [DropBand], nextValue: () -> [DropBand]) { value += nextValue() }
}
struct DropBandReader: View {
  let first: Double, per: Double, joins: Set<UUID>, clips: Set<UUID>
  var body: some View {
    GeometryReader { geo in
      Color.clear.preference(
        key: DropBandKey.self,
        value: [
          DropBand(rect: geo.frame(in: .global), first: first, per: per, joins: joins, clips: clips)
        ])
    }
  }
}
private struct TransitionCardDrag: NSViewRepresentable {
  let e: Editor
  let look: TransitionLook
  func makeNSView(context: Context) -> Surface {
    let v = Surface()
    v.card = self
    return v
  }
  func updateNSView(_ view: Surface, context: Context) { view.card = self }
  final class Surface: NSView {
    var card: TransitionCardDrag?, start = CGPoint.zero, dragged = false
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
      super.resetCursorRects()
      addCursorRect(bounds, cursor: .openHand)
    }
    override func mouseDown(with event: NSEvent) {
      start = event.locationInWindow
      dragged = false
    }
    private enum Destination {
      case join(Project.Join)
      case edge(EdgeTarget)
    }
    private func target(_ event: NSEvent) -> Destination? {
      guard let card else { return nil }
      guard let content = window?.contentView else { return nil }
      let point = content.convert(event.locationInWindow, from: nil)
      let global = CGPoint(
        x: point.x, y: content.isFlipped ? point.y : content.bounds.height - point.y)
      guard let band = card.e.dropBands.first(where: { $0.rect.contains(global) }) else {
        return nil
      }
      let frame = band.first + (global.x - band.rect.minX) / band.per
      if card.e.shelf.transitionSection == .edge {
        let ends = card.e.p.clips.filter { band.clips.contains($0.id) }.flatMap { c in
          // Use the marker's inside offset to distinguish two ends at the same cut.
          let inset = min(8 / band.per, Double(c.length) * 0.24)
          return [
            (EdgeTarget(clipID: c.id, end: .head), Double(c.start) + inset),
            (EdgeTarget(clipID: c.id, end: .tail), Double(c.end) - inset),
          ]
        }
        guard let nearest = ends.min(by: { abs($0.1 - frame) < abs($1.1 - frame) }),
          abs(nearest.1 - frame) * band.per <= 29
        else { return nil }
        return .edge(nearest.0)
      }
      let near = card.e.p.joins.filter { band.joins.contains($0.id) }.min {
        abs(Double($0.frame) - frame) < abs(Double($1.frame) - frame)
      }
      guard let near, abs(Double(near.frame) - frame) * band.per <= 38 else { return nil }
      return .join(near)
    }
    override func mouseDragged(with event: NSEvent) {
      guard let card else { return }
      if !dragged {
        guard hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 3
        else { return }
        dragged = true
        NSCursor.closedHand.push()
      }
      var join: UUID?
      var edge: EdgeTarget?
      switch target(event) {
      case .join(let value): join = value.id
      case .edge(let value): edge = value
      case nil: break
      }
      if card.e.shelf.dropJoin != join { card.e.shelf.dropJoin = join }
      if card.e.shelf.dropEdge != edge { card.e.shelf.dropEdge = edge }
    }
    override func mouseUp(with event: NSEvent) {
      guard let card else { return }
      guard dragged else {
        card.e.applyTransitionCard(card.look)
        return
      }
      dragged = false
      NSCursor.pop()
      card.e.shelf.dropJoin = nil
      card.e.shelf.dropEdge = nil
      let frames = card.e.shelf.transitionFrames
      switch target(event) {
      case .join(let join):
        card.e.chooseJoin(join)
        card.e.shelf.transitionFrames = frames
        card.e.transition(join.id, frames: frames, style: card.look)
      case .edge(let edge):
        card.e.edgeTransition(edge, frames: frames, style: card.look)
      case nil: break
      }
    }
  }
}
private struct TransitionSwatch: View {
  let look: TransitionLook
  var body: some View {
    SwiftUI.Canvas { ctx, size in
      let box = CGRect(origin: .zero, size: size)
      let blue = Color(red: 0.34, green: 0.43, blue: 0.70)
      let mint = Color(red: 0.38, green: 0.74, blue: 0.68)
      ctx.fill(Path(box), with: .color(UI.panel))
      switch look {
      case .slide:
        ctx.fill(Path(CGRect(x: 5, y: 7, width: 23, height: 18)), with: .color(blue))
        ctx.fill(Path(CGRect(x: 25, y: 7, width: 20, height: 18)), with: .color(mint))
        for x in [1.0, 4.0, 29.0] {
          ctx.fill(
            Path(CGRect(x: x, y: 12, width: 6, height: 1)), with: .color(.white.opacity(0.6)))
        }
      case .flip:
        let left = [
          CGPoint(x: 5, y: 6), CGPoint(x: 21, y: 11),
          CGPoint(x: 21, y: 22), CGPoint(x: 5, y: 27),
        ]
        let right = [
          CGPoint(x: 27, y: 11), CGPoint(x: 44, y: 6),
          CGPoint(x: 44, y: 27), CGPoint(x: 27, y: 22),
        ]
        for (points, color) in [(left, blue), (right, mint)] {
          ctx.fill(
            Path {
              $0.addLines(points)
              $0.closeSubpath()
            }, with: .color(color))
        }
      case .zoom:
        let layers: [(CGFloat, Color)] = [(40, blue.opacity(0.4)), (29, blue), (17, mint)]
        for (width, color) in layers {
          let r = CGRect(
            x: (size.width - width) / 2, y: (size.height - width * 0.59) / 2, width: width,
            height: width * 0.59)
          ctx.stroke(Path(r), with: .color(color), lineWidth: 1.5)
        }
      case .comparison:
        ctx.fill(Path(box.insetBy(dx: 4, dy: 5)), with: .color(blue))
        var split = Path()
        split.addLines([
          CGPoint(x: 4, y: 5), CGPoint(x: 29, y: 5),
          CGPoint(x: 18, y: 28), CGPoint(x: 4, y: 28),
        ])
        split.closeSubpath()
        ctx.fill(split, with: .color(mint))
        var line = Path()
        line.move(to: CGPoint(x: 29, y: 5))
        line.addLine(to: CGPoint(x: 18, y: 28))
        ctx.stroke(line, with: .color(.white), lineWidth: 2.8)
      case .dissolve, .warp, .glitch, .fire, .shake:
        let symbol: String
        let tint: Color
        switch look {
        case .dissolve:
          symbol = "circle.lefthalf.filled"
          tint = mint
        case .warp:
          symbol = "hurricane"
          tint = UI.accent
        case .glitch:
          symbol = "waveform.path"
          tint = .pink
        case .fire:
          symbol = "flame.fill"
          tint = .orange
        default:
          symbol = "waveform.path.ecg"
          tint = blue
        }
        ctx.draw(
          Text(Image(systemName: symbol)).font(.system(size: 18)).foregroundColor(tint),
          at: CGPoint(x: size.width / 2, y: size.height / 2))
      }
    }.frame(width: 50, height: 33).clipShape(RoundedRectangle(cornerRadius: 3)).accessibilityHidden(
      true)
  }
}
enum TransitionSection { case blur, edge, slide }
struct TransitionPanel: View {
  @ObservedObject var shelf: ShelfState
  let e: Editor
  @ObservedObject var updates: PanelUpdates
  private func pair(_ j: Project.Join) -> String { e.p.name(j.before) + " → " + e.p.name(j.after) }
  var body: some View {
    let joins = shelf.transitionSection == .blur ? e.p.joins : []
    let chosen = joins.first { $0.id == shelf.targetJoinID } ?? joins.first
    let edge = shelf.transitionSection == .edge ? e.edgeTarget : nil
    let current =
      edge.flatMap { target in
        e.p.clips.first(where: { $0.id == target.clipID })?.effect(at: target.end)?.style
      } ?? (chosen?.active == true ? chosen?.after.transitionStyle : nil)
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        Text("转场效果").font(.headline)
        Picker(
          "效果类型",
          selection: Binding(
            get: { shelf.transitionSection },
            set: { section in
              if section == .edge, let target = e.edgeTarget {
                e.chooseEdge(target)
              } else if section == .blur {
                let candidates = e.p.joins
                if let join = candidates.first(where: { $0.id == shelf.targetJoinID })
                  ?? candidates.first
                {
                  e.chooseJoin(join)
                } else {
                  shelf.transitionSection = .blur
                }
              } else {
                shelf.transitionSection = section
              }
            })
        ) {
          Text("接缝").tag(TransitionSection.blur)
          Text("首尾").tag(TransitionSection.edge)
          Text("滑入").tag(TransitionSection.slide)
        }.pickerStyle(.segmented).labelsHidden()
        if shelf.transitionSection == .blur { targetSettings(choices: joins, chosen: chosen) }
        if shelf.transitionSection == .edge { edgeSettings }
      }.padding(12)
      Divider()
      ScrollView {
        if shelf.transitionSection == .slide {
          VStack(alignment: .leading, spacing: 8) { SlideEntrancePanel(e: e, updates: updates) }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        } else {
          VStack(alignment: .leading, spacing: 5) {
            ForEach(TransitionLook.allCases, id: \.self) { look in
              card(look, active: current == look)
            }
          }.padding(10)
        }
      }
    }
  }

  @ViewBuilder private func targetSettings(choices: [Project.Join], chosen: Project.Join?)
    -> some View
  {
    if let join = chosen {
      MenuField(
        title: "片段接缝", choices: choices.map { tc($0.frame) + "  " + pair($0) },
        selectedIndex: choices.firstIndex { $0.id == join.id } ?? 0
      ) { index in e.chooseJoin(choices[index]) }.frame(height: 21)
      Picker("转场时长", selection: $shelf.transitionFrames) {
        let values = Array(Set([9, 15, 30, shelf.transitionFrames])).sorted()
        ForEach(values, id: \.self) { v in
          Text(String(format: "%.2g 秒", Double(v) / 30)).tag(v)
        }
      }.labelsHidden().pickerStyle(.segmented)
      if join.active {
        HStack(spacing: 6) {
          Button("播放", action: { e.previewJoin(join.id) }).accessibilityLabel("播放转场")
          Button("更新时长", action: { e.transition(join.id, frames: shelf.transitionFrames) })
            .disabled(shelf.transitionFrames == join.after.blend)
          Spacer(minLength: 0)
          Button("移除", action: { e.transition(join.id, frames: 0) }).accessibilityLabel("移除转场")
        }.controlSize(.small)
      }
    } else {
      Text("先将两个视频首尾相接，或在时间线上分割。")
        .font(.caption).foregroundStyle(UI.muted).fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder private var edgeSettings: some View {
    let choices = e.p.clips.filter { $0.kind == .video }.sorted { $0.start < $1.start }
    if let target = e.edgeTarget, let c = choices.first(where: { $0.id == target.clipID }) {
      MenuField(
        title: "素材", choices: choices.map { tc($0.start) + "  " + e.p.name($0) },
        selectedIndex: choices.firstIndex { $0.id == c.id } ?? 0
      ) { index in
        e.chooseEdge(EdgeTarget(clipID: choices[index].id, end: target.end))
      }.frame(height: 21)
      Picker(
        "素材首尾",
        selection: Binding(
          get: { target.end },
          set: { side in
            e.chooseEdge(EdgeTarget(clipID: target.clipID, end: side))
          })
      ) {
        ForEach(ClipEnd.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }.pickerStyle(.segmented).labelsHidden()
      Picker("首尾转场时长", selection: $shelf.transitionFrames) {
        ForEach(Array(Set([9, 15, 30, shelf.transitionFrames])).sorted(), id: \.self) { frames in
          Text(String(format: "%.2g 秒", Double(frames) / 30)).tag(frames)
        }
      }.labelsHidden().pickerStyle(.segmented)
      if let effect = c.effect(at: target.end) {
        HStack(spacing: 5) {
          Button("播放") { e.previewEdge(target) }.accessibilityLabel("播放首尾转场")
          Button("更新时长") { e.edgeTransition(target, frames: shelf.transitionFrames) }
            .disabled(shelf.transitionFrames == effect.frames)
          Spacer(minLength: 0)
          Button("移除") { e.edgeTransition(target, frames: 0) }.accessibilityLabel("移除首尾转场")
        }.controlSize(.small)
      }
    } else {
      Text("先选择图片或视频片段。").font(.caption).foregroundStyle(UI.muted)
    }
  }

  private func card(_ look: TransitionLook, active: Bool) -> some View {
    return HStack(spacing: 7) {
      TransitionSwatch(look: look)
      Text(look.rawValue).font(.system(size: 12, weight: .semibold))
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Image(systemName: active ? "checkmark" : "hand.draw").font(.system(size: 10))
        .foregroundStyle(active ? UI.accent : UI.muted)
    }.padding(5).background(
      active ? UI.accent.opacity(0.16) : UI.deep,
      in: RoundedRectangle(cornerRadius: 5)
    )
    .contentShape(Rectangle()).overlay { TransitionCardDrag(e: e, look: look) }
    .help(shelf.transitionSection == .edge ? "点按应用到当前首端或末端。" : "点按应用到当前接缝，也可拖到时间线接缝。")
    .accessibilityElement(children: .ignore).accessibilityLabel(look.rawValue + "效果卡")
    .accessibilityAddTraits(.isButton).accessibilityAction { e.applyTransitionCard(look) }
  }
}

private struct SlideEntrancePanel: View {
  let e: Editor
  @ObservedObject var updates: PanelUpdates
  @State private var frames = 15
  private var items: [Clip] { e.p.clips.filter(\.supportsMotion).sorted { $0.start < $1.start } }
  private var target: Clip? {
    if let c = e.clip, c.supportsMotion { return c }
    return items.first { $0.start <= e.transport.frame && e.transport.frame < $0.end }
      ?? items.first
  }
  private func update(_ c: Clip?) {
    frames = c.flatMap { $0.entranceFrames > 0 ? $0.entranceFrames : nil } ?? 15
  }
  var body: some View {
    if let c = target {
      SectionName(name: "目标片段")
      let choices = items
      MenuField(
        title: "滑入目标", choices: choices.map { tc($0.start) + "  " + e.p.name($0) },
        selectedIndex: choices.firstIndex { $0.id == c.id } ?? 0
      ) { e.selected = choices[$0].id }
      .frame(height: 21)
      NumberRow(
        label: "滑入时长", value: Double(frames) / 30, range: 1.0 / 30...10, unit: "秒", precision: 2
      ) { frames = max(1, Int(($0 * 30).rounded())) }
      Button(c.entranceFrames > 0 ? "更新滑入" : "添加滑入") {
        e.selected = c.id
        e.edit(c.id) { $0.setSlide(frames) }
        e.seek(c.start)
      }.buttonStyle(PrimaryButton()).onAppear { update(c) }.onChange(of: c.id) { _ in update(c) }
      if c.entranceFrames > 0 {
        Button("移除滑入") { e.edit(c.id) { $0.setSlide(0) } }
      }
      Text("片段从画面左侧滑入。可以与摇晃同时使用。").font(.caption).foregroundStyle(UI.muted)
    } else {
      Text("请先添加视频、文字、图形或字幕。").foregroundStyle(UI.muted)
    }
  }
}
