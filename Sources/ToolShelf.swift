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
  case charts = "图表"
  case quickEdit = "快剪"
  var id: Self { self }
  var tint: Color {
    switch self {
    case .media: return UI.color(.video)
    case .annotations: return UI.coral
    case .transitions, .filters: return UI.accent
    case .captions: return UI.buttonTint
    case .sounds: return UI.mint
    case .charts: return UI.mint
    case .quickEdit: return UI.buttonTint
    }
  }
  var symbol: String {
    switch self {
    case .filters: return "camera.filters"
    case .sounds: return "waveform"
    case .captions: return "captions.bubble"
    case .media: return "film.stack"
    case .annotations: return "pencil.tip"
    case .transitions: return "rectangle.2.swap"
    case .charts: return "chart.bar.xaxis"
    case .quickEdit: return "bolt"
    }
  }
  @ViewBuilder func content(_ e: Editor) -> some View {
    switch self {
    case .filters: FilterPanel(editor: e, updates: e.panelUpdates(self))
    case .sounds: SoundPanel(e: e, shelf: e.shelf)
    case .captions: CaptionPanel(e: e, updates: e.panelUpdates(self), automatic: e.automaticCaptions)
    case .media: Library(e: e, updates: e.panelUpdates(self))
    case .annotations: AnnotationPanel(e: e, updates: e.panelUpdates(self))
    case .transitions: TransitionPanel(shelf: e.shelf, e: e, updates: e.panelUpdates(self))
    case .charts: ChartPanel(editor: e, updates: e.panelUpdates(self))
    case .quickEdit: QuickEditPanel(editor: e, updates: e.panelUpdates(self))
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
    private let railWidth: CGFloat = AppLanguage.current == .english ? 72 : 48
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
      rail.setAccessibilityLabel(L("工具栏"))
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
  private var active = false
  private var hovering = false
  private var hoverArea: NSTrackingArea?
  private let selectionBar = CALayer()

  init(tab: ToolTab, target: AnyObject, action: Selector) {
    self.tab = tab
    super.init(frame: .zero)
    self.target = target
    self.action = action
    isBordered = false
    imagePosition = .imageAbove
    image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
    toolTip = LKey(tab.rawValue) + L("面板")
    setAccessibilityLabel(LKey(tab.rawValue))
    setButtonType(.momentaryChange)
    focusRingType = .exterior
    wantsLayer = true
    layer?.cornerRadius = 7
    layer?.addSublayer(selectionBar)
    layer?.borderWidth = 1
    selectionBar.cornerRadius = 1
    updateStyle()
  }
  required init?(coder: NSCoder) { fatalError() }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    selectionBar.frame = CGRect(x: 0, y: (bounds.height - 16) / 2, width: 2, height: 16)
    CATransaction.commit()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea { removeTrackingArea(hoverArea) }
    let area = NSTrackingArea(
      rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    hoverArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    hovering = true
    updateStyle()
  }

  override func mouseExited(with event: NSEvent) {
    hovering = false
    updateStyle()
  }

  func markSelected(_ next: Bool) {
    guard next != active else { return }
    active = next
    updateStyle()
  }

  private func updateStyle() {
    let tint = NSColor(tab.tint)
    let color = active ? tint : hovering ? .white : NSColor(UI.muted)
    contentTintColor = color
    attributedTitle = NSAttributedString(
      string: LKey(tab.rawValue),
      attributes: [
        .font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: color,
      ])
    let fill = tint.withAlphaComponent(active ? 0.19 : hovering ? 0.10 : 0.02).cgColor
    let previous = layer?.presentation()?.backgroundColor ?? layer?.backgroundColor
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer?.backgroundColor = fill
    layer?.borderColor = tint.withAlphaComponent(active ? 0.40 : hovering ? 0.24 : 0.08).cgColor
    selectionBar.backgroundColor = active ? tint.cgColor : NSColor.clear.cgColor
    CATransaction.commit()
    if let previous, window?.isKeyWindow == true,
      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      let fade = CABasicAnimation(keyPath: "backgroundColor")
      fade.fromValue = previous
      fade.toValue = fill
      fade.duration = 0.13
      layer?.add(fade, forKey: "toolTint")
    }
    setAccessibilityValue(active ? L("已选") : nil)
  }
}
struct DropBand: Equatable {
  let rect: CGRect
  let originX: Double, first: Double, per: Double
  let joins: [Project.Join]
  let clips: [Clip]
}
struct DropBandKey: PreferenceKey {
  static let coordinateSpace = "TransitionDropWorkspace"
  static var defaultValue: [DropBand] { [] }
  static func reduce(value: inout [DropBand], nextValue: () -> [DropBand]) { value += nextValue() }
}
struct DropBandReader: View {
  let first: Double, per: Double
  let joins: [Project.Join]
  let clips: [Clip]
  let viewport: CGRect

  var body: some View {
    GeometryReader { geo in
      let band = geo.frame(in: .named(DropBandKey.coordinateSpace))
      let visible = band.intersection(viewport)
      Color.clear.preference(
        key: DropBandKey.self,
        value: visible.isEmpty ? [] : [
          DropBand(rect: visible, originX: band.minX, first: first, per: per, joins: joins, clips: clips)
        ])
    }
  }
}

struct TransitionDragSurface: NSViewRepresentable {
  enum Origin {
    case card(TransitionLook)
    case marker(TransitionTarget)
  }
  let e: Editor
  let origin: Origin
  func makeNSView(context: Context) -> Surface {
    let view = Surface()
    view.drag = self
    return view
  }
  func updateNSView(_ view: Surface, context: Context) { view.drag = self }

  final class Surface: NSView {
    var drag: TransitionDragSurface?
    private var start = CGPoint.zero
    private var dragging = false
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
      super.resetCursorRects()
      addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
      start = event.locationInWindow
      dragging = false
    }
    private func targets(_ event: NSEvent) -> [TransitionTarget] {
      guard let drag, let content = window?.contentView else { return [] }
      let point = content.convert(event.locationInWindow, from: nil)
      let workspace = CGPoint(
        x: point.x, y: content.isFlipped ? point.y : content.bounds.height - point.y)
      guard let band = drag.e.dropBands.first(where: { $0.rect.contains(workspace) }) else { return [] }
      let bothEnds: Bool
      switch drag.origin {
      case .card: bothEnds = true
      case .marker: bothEnds = false
      }
      return TransitionTarget.at(
        x: workspace.x - band.originX, first: band.first, per: band.per, clips: band.clips,
        joins: band.joins, bothEnds: bothEnds)
    }
    override func mouseDragged(with event: NSEvent) {
      guard let drag else { return }
      if !dragging {
        guard hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 3
        else { return }
        dragging = true
        NSCursor.closedHand.push()
      }
      let next = targets(event)
      if drag.e.shelf.dropTargets != next { drag.e.shelf.dropTargets = next }
    }
    override func mouseUp(with event: NSEvent) {
      guard let drag else { return }
      guard dragging else {
        switch drag.origin {
        case .card(let look): drag.e.applyTransitionCard(look)
        case .marker(let target): drag.e.selectTransition(target)
        }
        return
      }
      dragging = false
      NSCursor.pop()
      let next = targets(event)
      drag.e.shelf.dropTargets = []
      switch drag.origin {
      case .card(let look):
        drag.e.placeTransition(look, on: next)
      case .marker(let target):
        if let destination = next.first { drag.e.moveTransition(from: target, to: destination) }
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
      case .unfold:
        let frame = box.insetBy(dx: 4, dy: 5)
        ctx.fill(Path(frame), with: .color(blue))
        ctx.fill(Path(frame.insetBy(dx: frame.width * 0.28, dy: 0)), with: .color(mint))
        var arrows = Path()
        for direction in [-1.0, 1.0] {
          let tip = frame.midX + direction * 15
          arrows.move(to: CGPoint(x: frame.midX + direction * 4, y: frame.midY))
          arrows.addLine(to: CGPoint(x: tip, y: frame.midY))
          arrows.move(to: CGPoint(x: tip - direction * 4, y: frame.midY - 3))
          arrows.addLine(to: CGPoint(x: tip, y: frame.midY))
          arrows.addLine(to: CGPoint(x: tip - direction * 4, y: frame.midY + 3))
        }
        ctx.stroke(arrows, with: .color(.white), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
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
enum TransitionSection { case effects, slide }
struct TransitionPanel: View {
  @ObservedObject var shelf: ShelfState
  let e: Editor
  @ObservedObject var updates: PanelUpdates

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      PanelSegments(
        title: L("效果类型"), options: [TransitionSection.effects, .slide],
        selection: $shelf.transitionSection
      ) { $0 == .effects ? L("转场") : L("滑入") }.padding(12)
      Divider()
      ScrollView {
        if shelf.transitionSection == .slide {
          VStack(alignment: .leading, spacing: 8) { SlideEntrancePanel(e: e, updates: updates) }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        } else {
          let current = e.selectedTransition.flatMap { e.p.transitionEffect($0)?.style }
          VStack(alignment: .leading, spacing: 5) {
            Text(L("把效果拖到素材首端、末端或接缝。拖到素材中间可在两端添加。"))
              .font(.caption).foregroundStyle(UI.muted).fixedSize(horizontal: false, vertical: true)
              .padding(.bottom, 5)
            ForEach(TransitionLook.allCases, id: \.self) { look in
              card(look, active: current == look)
            }
          }.padding(10)
        }
      }
    }
  }

  private func card(_ look: TransitionLook, active: Bool) -> some View {
    HStack(spacing: 7) {
      TransitionSwatch(look: look)
      Text(LKey(look.rawValue)).font(.system(size: 12, weight: .semibold))
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Image(systemName: active ? "checkmark" : "line.3.horizontal").font(.system(size: 10))
        .foregroundStyle(active ? UI.accent : UI.muted)
    }.padding(5).background(
      active ? UI.accent.opacity(0.16) : UI.deep,
      in: RoundedRectangle(cornerRadius: 5)
    )
    .contentShape(Rectangle()).overlay { TransitionDragSurface(e: e, origin: .card(look)) }
    .help(L("拖到时间线，或点按应用到选中的素材或转场"))
    .accessibilityElement(children: .ignore).accessibilityLabel(LKey(look.rawValue) + L("效果卡"))
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
      SectionName(name: L("目标片段"))
      let choices = items
      MenuField(
        title: L("滑入目标"), choices: choices.map { tc($0.start) + "  " + e.p.name($0) },
        selectedIndex: choices.firstIndex { $0.id == c.id } ?? 0
      ) { e.selected = choices[$0].id }
      .frame(height: 21)
      NumberRow(
        label: L("滑入时长"), value: Double(frames) / 30, range: 1.0 / 30...10, unit: L("秒"), precision: 2
      ) { frames = max(1, Int(($0 * 30).rounded())) }
      Button(c.entranceFrames > 0 ? L("更新滑入") : L("添加滑入")) {
        e.selected = c.id
        e.edit(c.id) { $0.setSlide(frames) }
        e.seek(c.start)
      }.buttonStyle(PrimaryButton()).onAppear { update(c) }.onChange(of: c.id) { _ in update(c) }
      if c.entranceFrames > 0 {
        Button(L("移除滑入")) { e.edit(c.id) { $0.setSlide(0) } }
      }
      Text(L("片段从画面左侧滑入。可以与摇晃同时使用。")).font(.caption).foregroundStyle(UI.muted)
    } else {
      Text(L("请先添加视频、文字、图形或字幕。")).foregroundStyle(UI.muted)
    }
  }
}
