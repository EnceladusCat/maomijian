import SwiftUI

struct NumberRow: View {
  let label: String, value: Double, range: ClosedRange<Double>, unit: String
  var precision = 0
  var mixed = false
  var fieldWidth: CGFloat? = nil
  let done: (Double) -> Void
  var body: some View {
    NumberRowLayout {
      Text(label).font(.system(size: 12)).foregroundStyle(UI.muted)
      HStack(spacing: 5) {
        NumericControl(row: self).frame(width: fieldWidth ?? (52 + CGFloat(min(precision, 3)) * 3), height: 21)
        if !unit.isEmpty {
          Text(unit).font(.system(size: 12)).foregroundStyle(UI.muted)
        }
      }.fixedSize()
    }
  }
  var formatted: String { mixed ? "" : format(value) }
  func format(_ number: Double) -> String {
    range.upperBound.isInfinite && number >= 1e8 ? String(number)
      : String(format: "%.*f", precision, number)
  }
}

private struct NumberRowLayout: Layout {
  private let spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let label = subviews[0].sizeThatFits(.unspecified)
    let input = subviews[1].sizeThatFits(.unspecified)
    let ideal = label.width + spacing + input.width
    let width = max(input.width, proposal.width ?? ideal)
    if width >= ideal { return CGSize(width: width, height: max(label.height, input.height)) }
    let wrappedLabel = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
    return CGSize(width: width, height: wrappedLabel.height + 4 + input.height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let label = subviews[0].sizeThatFits(.unspecified)
    let input = subviews[1].sizeThatFits(.unspecified)
    if bounds.width >= label.width + spacing + input.width {
      subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
      subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
    } else {
      subviews[0].place(at: bounds.origin, anchor: .topLeading,
                        proposal: ProposedViewSize(width: bounds.width, height: nil))
      subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.maxY), anchor: .bottomTrailing, proposal: .unspecified)
    }
  }
}

private struct NumericControl: NSViewRepresentable {
  let row: NumberRow
  func makeNSView(context: Context) -> Field { Field(frame: .zero) }
  func updateNSView(_ view: Field, context: Context) { view.configure(row) }

  final class Field: NSTextField, NSTextFieldDelegate {
    private var row: NumberRow?

    override init(frame: NSRect) {
      super.init(frame: frame)
      alignment = .right
      font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
      delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ next: NumberRow) {
      let previous = row
      row = next
      if previous?.label != next.label { setAccessibilityLabel(next.label) }
      placeholderString = next.mixed ? L("混合") : nil
      if previous?.value != next.value || previous?.mixed != next.mixed || currentEditor() == nil {
        if stringValue != next.formatted { stringValue = next.formatted }
      }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
      guard let row else { return }
      let text = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard text != row.formatted, let number = Double(text), number.isFinite else {
        stringValue = row.formatted
        return
      }
      let value = bound(number, row.range.lowerBound, row.range.upperBound)
      stringValue = row.format(value)
      if row.mixed || abs(row.value - value) > 1e-8 { row.done(value) }
    }
  }
}
private struct Writing: View {
  let value: String, apply: (String) -> Void
  @State private var buffer = ""
  @FocusState private var focused: Bool
  var body: some View {
    TextEditor(text: $buffer).focused($focused).font(.body).frame(height: 62).padding(3)
      .accessibilityLabel(L("正文"))
      .background(UI.deep, in: RoundedRectangle(cornerRadius: 4))
      .onAppear { buffer = value }.onChange(of: value) { v in if v != buffer { buffer = v } }
      .onChange(of: buffer) { v in if v != value { apply(v) } }
  }
}
struct InspectorHost: NSViewRepresentable {
  let editor: Editor
  func makeNSView(context: Context) -> NSView {
    let host = NSHostingView(
      rootView: Inspector(e: editor).foregroundStyle(Color.white).preferredColorScheme(.dark))
    host.sizingOptions = []
    return host
  }
  func updateNSView(_ view: NSView, context: Context) {}
}
struct Inspector: View {
  @ObservedObject var e: Editor
  func num(
    _ label: String, _ c: Clip, _ key: WritableKeyPath<Clip, Double>, _ factor: Double,
    _ range: ClosedRange<Double>, _ unit: String, _ digits: Int = 0
  ) -> some View {
    NumberRow(
      label: label, value: c[keyPath: key] * factor, range: range, unit: unit, precision: digits
    ) { v in e.edit(c.id) { $0[keyPath: key] = v / factor } }
  }
  func colorControl(_ title: String, _ hex: String, apply: @escaping (String) -> Void) -> some View
  {
    ProjectColorPicker(title: title, hex: hex, apply: apply)
  }
  func shapePicker(_ selection: Binding<RegionShape>) -> some View {
    RegionShapePicker(selection: selection)
  }
  @ViewBuilder func mediaTiming(_ clips: [Clip]) -> some View {
    if let first = clips.first,
      clips.allSatisfy({ $0.kind.isMedia && e.p.asset($0.asset)?.isStill != true })
    {
      let ids = Set(clips.map(\.id))
      NumberRow(
        label: L("播放倍速"), value: first.rate, range: 0.25...4, unit: "×", precision: 2,
        mixed: clips.contains { $0.rate != first.rate }
      ) { e.adjustMedia(ids, rate: $0) }
      if clips.allSatisfy({ e.p.asset($0.asset)?.audio == true }) {
        NumberRow(
          label: L("音高"), value: first.pitch, range: -12...12, unit: L("半音"), precision: 1,
          mixed: clips.contains { $0.pitch != first.pitch }
        ) { e.adjustMedia(ids, pitch: $0) }
      }
    }
  }
  private func borderStyle(_ clip: Clip) -> Binding<CaptionBorder> {
    Binding(
      get: { (clip.visualBorder ?? VisualBorder()).style },
      set: { style in
        e.edit(clip.id) { c in
          var border = c.visualBorder ?? VisualBorder()
          border.style = style
          c.visualBorder = border
        }
      })
  }

  @ViewBuilder private func visualProperties(_ c: Clip) -> some View {
    SectionName(name: L("变换"))
    NumberRow(label: L("素材缩放"), value: c.displayScale * 100, range: 5...800, unit: "%") { v in
      e.edit(c.id) { $0.visualScale = v / 100 }
    }
    HStack {
      Tool(symbol: "rotate.left", label: L("向左旋转 90°")) {
        e.edit(c.id) { $0.angle = ($0.angle - 90).truncatingRemainder(dividingBy: 360) }
      }
      Tool(symbol: "rotate.right", label: L("向右旋转 90°")) {
        e.edit(c.id) { $0.angle = ($0.angle + 90).truncatingRemainder(dividingBy: 360) }
      }
      num(L("角度"), c, \.angle, 1, -360...360, "°", 1)
    }
    num(L("水平位置"), c, \.x, 100, -400...500, "%", 1)
    num(L("垂直位置"), c, \.y, 100, -400...500, "%", 1)
    num(L("不透明度"), c, \.opacity, 100, 0...100, "%")
    HStack {
      Button(e.cropID == c.id && e.selected == c.id ? L("完成裁剪") : L("裁剪素材")) { e.beginCrop(c) }
      if c.sourceCrop != nil { Button(L("重置裁剪")) { e.edit(c.id) { $0.sourceCrop = nil } } }
    }
    if e.cropID == c.id && e.selected == c.id {
      let crop = c.sourceCrop ?? SourceCrop()
      ForEach(0..<4, id: \.self) { edge in
        let title = [L("裁左"), L("裁上"), L("裁右"), L("裁下")][edge]
        let keys: [WritableKeyPath<SourceCrop, Double>] = [\.left, \.top, \.right, \.bottom]
        let key = keys[edge]
        NumberRow(
          label: title, value: crop[keyPath: key] * 100,
          range: 0...(98 - crop[keyPath: keys[(edge + 2) % 4]] * 100),
          unit: "%", precision: 1
        ) { v in
          e.edit(c.id) {
            var next = $0.sourceCrop ?? SourceCrop()
            next[keyPath: key] = v / 100
            $0.sourceCrop = next
          }
        }
      }
    }
    Divider()
    Picker(L("边框"), selection: borderStyle(c)) {
      ForEach(CaptionBorder.allCases, id: \.self) { Text(LKey($0.rawValue)).tag($0) }
    }
    if let border = c.visualBorder, border.style != .none {
      NumberRow(label: L("边框宽度"), value: border.width, range: 1...64, unit: "px") { value in
        e.edit(c.id) { $0.visualBorder?.width = value }
      }
      colorControl(L("边框颜色"), border.color) { color in e.edit(c.id) { $0.visualBorder?.color = color }
      }
    }
    if !c.filters.isEmpty {
      Divider()
      FilterStackRows(editor: e, clip: c)
    }
  }

  private func textBinding<T>(_ c: Clip, _ key: WritableKeyPath<TextAppearance, T>) -> Binding<T> {
    Binding(
      get: { (c.textAppearance ?? TextAppearance())[keyPath: key] },
      set: { value in
        e.edit(c.id) { clip in
          var appearance = clip.textAppearance ?? TextAppearance()
          appearance[keyPath: key] = value
          clip.textAppearance = appearance
        }
      })
  }
  private func animationBinding<T>(_ c: Clip, _ key: WritableKeyPath<TextAnimation, T>) -> Binding<T> {
    Binding(
      get: { (c.textAnimation ?? TextAnimation())[keyPath: key] },
      set: { value in
        e.edit(c.id) { clip in
          var animation = clip.textAnimation ?? TextAnimation()
          animation[keyPath: key] = value
          clip.textAnimation = animation
        }
      })
  }
  @ViewBuilder private func textMotion(_ c: Clip) -> some View {
    let animation = c.textAnimation ?? TextAnimation()
    SectionName(name: L("文字动画"))
    Toggle(L("粗下划线"), isOn: animationBinding(c, \.underline))
    Toggle(L("逐字切入切出"), isOn: animationBinding(c, \.characters))
    if animation.enabled {
      let range = 0...Double(max(c.length, animation.entryFrames, animation.exitFrames)) / Double(fps)
      NumberRow(label: L("入场时长"), value: Double(animation.entryFrames) / Double(fps),
                range: range, unit: L("秒"), precision: 2) {
        animationBinding(c, \.entryFrames).wrappedValue = Int(($0 * Double(fps)).rounded())
      }
      NumberRow(label: L("出场时长"), value: Double(animation.exitFrames) / Double(fps),
                range: range, unit: L("秒"), precision: 2) {
        animationBinding(c, \.exitFrames).wrappedValue = Int(($0 * Double(fps)).rounded())
      }
    }
  }
  private func editDuotone(_ c: Clip, _ apply: (inout TextDuotone) -> Void) {
    e.edit(c.id) { clip in
      var appearance = clip.textAppearance ?? TextAppearance()
      var style = appearance.duotone ?? TextDuotone()
      apply(&style)
      appearance.duotone = style
      clip.textAppearance = appearance
    }
  }
  @ViewBuilder private func duotoneControls(_ c: Clip) -> some View {
    Toggle(L("双色文字"), isOn: Binding(
      get: { c.textAppearance?.activeDuotone != nil },
      set: { enabled in editDuotone(c) { $0.enabled = enabled } }
    ))
    if let style = c.textAppearance?.activeDuotone {
      colorControl(L("第一色"), style.firstColor) { color in editDuotone(c) { $0.firstColor = color } }
      colorControl(L("第二色"), style.secondColor) { color in editDuotone(c) { $0.secondColor = color } }
      NumberRow(label: L("分界角度"), value: style.angle, range: -180...180, unit: "°") { value in
        editDuotone(c) { $0.angle = value }
      }
      NumberRow(label: L("第一色占比"), value: style.position * 100, range: 0...100, unit: "%") { value in
        editDuotone(c) { $0.position = value / 100 }
      }
    }
  }
  @ViewBuilder private func chartProperties(_ c: Clip, chart: ChartSpec) -> some View {
    Label(e.p.name(c), systemImage: chart.kind.icon).font(.callout).lineLimit(2)
    let count = chart.points.count
    Text(L("\(count) 条数据")).font(.caption).foregroundStyle(UI.muted)
    NumberRow(label: L("入场时长"), value: Double(chart.entryFrames) / Double(fps),
              range: 0...Double(max(chart.entryFrames, c.length - 1)) / Double(fps),
              unit: L("秒"), precision: 2) { value in
      e.edit(c.id) { $0.chart?.entryFrames = Int((value * Double(fps)).rounded()) }
    }
    Button { e.editChartData(c) } label: {
      Label(L("编辑图表数据"), systemImage: "tablecells").frame(maxWidth: .infinity)
    }.buttonStyle(QuietButton())
    ChartStyleControls(clip: c, kind: chart.kind, editor: e)
    Divider()
  }
  @ViewBuilder private func typography(_ c: Clip) -> some View {
    let appearance = c.textAppearance ?? TextAppearance()
    let fonts = [""] + CaptionPanel.families
    SectionName(name: L("文字样式"))
    MenuField(
      title: L("字体"), choices: [L("系统字体")] + CaptionPanel.families,
      selectedIndex: fonts.firstIndex(of: appearance.font) ?? 0
    ) {
      textBinding(c, \.font).wrappedValue = fonts[$0]
    }.frame(height: 21)
    NumberRow(label: L("字号"), value: appearance.size, range: 8...Double.infinity, unit: "px") { value in
      e.edit(c.id) { clip in
        var next = clip.textAppearance ?? TextAppearance()
        next.size = value
        next.fixedSize = true
        clip.textAppearance = next
      }
    }
    Toggle(L("粗体"), isOn: textBinding(c, \.bold))
    Picker(L("描边"), selection: textBinding(c, \.outline.style)) {
      ForEach(CaptionBorder.allCases, id: \.self) { Text(LKey($0.rawValue)).tag($0) }
    }
    if appearance.outline.style != .none {
      NumberRow(label: L("描边宽度"), value: appearance.outline.width, range: 1...64, unit: "px") {
        textBinding(c, \.outline.width).wrappedValue = $0
      }
      colorControl(L("描边颜色"), appearance.outline.color) {
        textBinding(c, \.outline.color).wrappedValue = $0
      }
    }
    TextShadowControls(value: appearance.shadow ?? TextShadow()) {
      textBinding(c, \.shadow).wrappedValue = $0
    }
  }

  private func timerBinding<T>(_ c: Clip, _ key: WritableKeyPath<TimerSettings, T>) -> Binding<T> {
    Binding(
      get: {
        (e.p.clips.first(where: { $0.id == c.id })?.timerSettings ?? TimerSettings())[keyPath: key]
      },
      set: { value in
        e.edit(c.id) { clip in
          var timer = clip.timerSettings ?? TimerSettings()
          timer[keyPath: key] = value
          clip.timerSettings = timer
        }
      })
  }
  @ViewBuilder private func timerProperties(_ c: Clip) -> some View {
    let timer = c.timerSettings ?? TimerSettings()
    SectionName(name: L("计时设置"))
    Picker(
      L("模式"),
      selection: Binding(
        get: { timer.direction },
        set: { direction in
          e.edit(c.id) {
            var next = $0.timerSettings ?? TimerSettings()
            if direction == .down && next.initialSeconds == 0 { next.initialSeconds = 10 }
            next.direction = direction
            $0.timerSettings = next
          }
        })
    ) {
      ForEach(TimerDirection.allCases, id: \.self) { Text(LKey($0.rawValue)).tag($0) }
    }
    NumberRow(label: L("起始值"), value: timer.initialSeconds, range: 0...86400, unit: L("秒"), precision: 1)
    {
      timerBinding(c, \.initialSeconds).wrappedValue = $0
    }
    if timer.direction == .custom {
      NumberRow(label: L("流速"), value: timer.speed, range: -100...100, unit: "×", precision: 2) {
        timerBinding(c, \.speed).wrappedValue = $0
      }
    }
    Picker(L("格式"), selection: timerBinding(c, \.format)) {
      ForEach(TimerFormat.allCases, id: \.self) { Text(LKey($0.rawValue)).tag($0) }
    }
    TextField(L("前缀单位"), text: timerBinding(c, \.prefix)).accessibilityLabel(L("前缀单位"))
    TextField(L("后缀单位"), text: timerBinding(c, \.suffix)).accessibilityLabel(L("后缀单位"))
  }
  private func editShape(_ clip: Clip, _ update: (inout ShapeAppearance) -> Void) {
    e.edit(clip.id) { next in
      var appearance = next.shapeAppearance ?? ShapeAppearance(fill: next.shapeFill)
      update(&appearance)
      next.shapeAppearance = appearance
    }
  }

  @ViewBuilder private func shapeStyle(_ clip: Clip) -> some View {
    let appearance = clip.shapeAppearance ?? ShapeAppearance()
    PanelSegments(
      title: L("填充方式"), options: ShapeFill.allCases,
      selection: Binding(get: { clip.shapeFill }, set: { value in
        editShape(clip) { $0.fill = value }
      }), tint: UI.mint
    ) { $0.title }
    SectionName(name: L("边缘样式"))
    PanelSegments(
      title: L("边缘样式"), options: ShapeEdge.allCases,
      selection: Binding(get: { appearance.edge }, set: { value in
        editShape(clip) { $0.edge = value }
      }), tint: UI.mint
    ) { $0.title }
    if clip.shapeFill == .hollow {
      let defaultWidth = e.p.canvas.size(1080).height * 0.006
      NumberRow(label: L("描边宽度"), value: appearance.outlineWidth ?? defaultWidth,
                range: 1...64, unit: "px", precision: 1) { value in
        editShape(clip) { $0.outlineWidth = value }
      }
    }
    if appearance.edge == .rough {
      NumberRow(label: L("粗犷程度"), value: appearance.roughness * 100, range: 0...100, unit: "%") {
        value in editShape(clip) { $0.roughness = value / 100 }
      }
    }
    Divider()
  }

  @ViewBuilder func details(_ c: Clip) -> some View {
    Label(e.p.asset(c.asset)?.isStill == true ? L("图片") : c.kind.title, systemImage: c.kind.icon).font(
      .headline
    ).foregroundStyle(UI.color(c.kind))
    if c.kind == .chart, let chart = c.chart { chartProperties(c, chart: chart) }
    if let visual = c.audioVisualization { AudioVisualizationControls(editor: e, clip: c, visual: visual) }
    if let spec = c.editorial { EditorialControls(editor: e, clip: c, spec: spec).id(c.id) }
    if c.supportsMotion {
      motionControls(c)
      Divider()
    }
    if let inset = c.pictureInset, c.kind == .video { PictureInsetControls(editor: e, clip: c, inset: inset) }
    if c.kind.supportsShapeAppearance { shapeStyle(c) }
    if c.kind.isRegion {
      Text(L("拖动选框调整位置，拉四角改变范围。")).font(.caption).foregroundStyle(UI.muted)
      shapePicker(
        Binding(
          get: { c.shape },
          set: { v in
            e.edit(c.id) {
              $0.regionShape = v
              $0.setRegion(v.fit($0.region, in: e.p.canvas.size(540)))
            }
          }))
      if c.kind == .zoom {
        colorControl(L("边框颜色"), c.border) { hex in e.edit(c.id) { $0.borderColor = hex } }
        NumberRow(
          label: L("边框宽度"), value: c.lensBorderWidth ?? Clip.defaultLensBorderWidth,
          range: 0...64, unit: "px", precision: 1
        ) { value in e.edit(c.id) { $0.lensBorderWidth = value } }
        num(L("放大倍率"), c, \.scale, 1, 1...5, "×", 2)
        NumberRow(
          label: L("进入时长"), value: Double(c.entryFrames) / 30, range: 0...Double(c.length) / 30,
          unit: L("秒"), precision: 2
        ) { v in
          e.edit(c.id) { $0.zoomInFrames = Int((v * 30).rounded()) }
        }
        NumberRow(
          label: L("退出时长"), value: Double(c.exitFrames) / 30, range: 0...Double(c.length) / 30,
          unit: L("秒"), precision: 2
        ) { v in
          e.edit(c.id) { $0.zoomOutFrames = Int((v * 30).rounded()) }
        }
        if c.entryFrames + c.exitFrames > c.length - 1 {
          Text(L("片段较短，进出时长会按比例缩短。")).font(.caption).foregroundStyle(UI.muted)
        }
      } else {
        num(L("框外暗度"), c, \.opacity, 100, 0...100, "%")
        Toggle(L("淡入"), isOn: Binding(
          get: { c.highlightFadeIn == true }, set: { value in e.edit(c.id) { $0.highlightFadeIn = value } }
        ))
        Toggle(L("淡出"), isOn: Binding(
          get: { c.highlightFadeOut == true }, set: { value in e.edit(c.id) { $0.highlightFadeOut = value } }
        ))
      }
      if c.shape == .rectangle {
        num(L("区域宽度"), c, \.w, 100, 1...100, "%")
        num(L("区域高度"), c, \.h, 100, 1...100, "%")
      } else {
        let size = e.p.canvas.size(540)
        let box = c.shape.fit(c.region, in: size)
        let short = min(size.width, size.height)
        NumberRow(
          label: c.shape == .circle ? L("直径") : L("边长"),
          value: Double(box.width * size.width / short) * 100,
          range: 2...100, unit: "%"
        ) { v in
          e.edit(c.id) {
            $0.w = v / 100 * Double(short / size.width)
            $0.h = v / 100 * Double(short / size.height)
          }
        }
      }
      Divider()
    }
    if c.kind.isMedia { Text(e.p.name(c)).lineLimit(2).foregroundStyle(UI.muted) }
    NumberRow(
      label: L("开始时间"), value: Double(c.start) / 30, range: 0...Double(maxFrames - c.length) / 30,
      unit: L("秒"), precision: 3
    ) { e.move(c, by: Int(($0 * 30).rounded()) - c.start, edge: 0) }
    let still = e.p.asset(c.asset)?.isStill == true
    let maxLength =
      still
      ? maxFrames - c.start : c.maximumLength(assetFrames: e.p.asset(c.asset)?.frames ?? maxFrames)
    NumberRow(
      label: L("持续时间"), value: Double(c.length) / 30, range: 1.0 / 30...Double(maxLength) / 30,
      unit: L("秒"), precision: 3
    ) { e.move(c, by: Int(($0 * 30).rounded()) - c.length, edge: 1) }
    if c.kind.isMedia && !still {
      mediaTiming([c])
      Text(L("素材入点  ") + tc(c.offset)).font(.caption.monospacedDigit()).foregroundStyle(UI.muted)
      if e.p.asset(c.asset)?.audio == true {
        Divider()
        num(L("音量"), c, \.volume, 100, 0...300, "%")
        if c.kind == .video { Button(L("分离音频"), action: e.detach).disabled(c.volume == 0) }
      }
    }
    if c.kind == .video {
      Divider()
      visualProperties(c)
    }
    if c.kind == .timer {
      Divider()
      timerProperties(c)
    }
    if c.kind == .text || c.kind == .caption {
      Divider()
      SectionName(name: L("正文"))
      Writing(value: c.text) { v in e.edit(c.id) { $0.text = v } }
    }
    if c.kind == .text {
      duotoneControls(c)
      Divider()
      textMotion(c)
    }
    if !c.kind.isMedia {
      Divider()
      SectionName(name: c.kind.isRegion ? L("选区中心") : L("画布位置"))
      num(L("水平"), c, \.x, 100, 0...100, "%")
      num(L("垂直"), c, \.y, 100, 0...100, "%")
    }
    if c.kind.isArt && !c.kind.isRegion {
      num(L("宽度"), c, \.w, 100, 1...200, "%")
      num(L("高度"), c, \.h, 100, 1...200, "%")
      num(L("旋转"), c, \.angle, 1, -360...360, "°")
      num(L("不透明度"), c, \.opacity, 100, 0...100, "%")
      if c.kind == .caption {
        Button(L("全局字幕样式")) { e.openTab(.captions) }
      } else if c.kind != .chart && c.kind != .audioVisual {
        colorControl(L("颜色"), c.color) { hex in e.edit(c.id) { $0.color = hex } }
      }
      if c.kind.supportsRelief {
        Picker(L("3D 样式"), selection: Binding(
          get: { c.reliefStyle ?? .flat }, set: { value in
            e.edit(c.id) {
              if $0.kind.supportsShapeAppearance && $0.shapeAppearance?.fill == nil {
                let fill = $0.shapeFill
                $0.shapeAppearance = $0.shapeAppearance ?? ShapeAppearance()
                $0.shapeAppearance?.fill = fill
              }
              $0.reliefStyle = value == .flat ? nil : value
            }
          }
        )) {
          ForEach(ReliefStyle.allCases, id: \.self) { Text($0.title).tag($0) }
        }
      }
    }
    if c.kind == .text || c.kind == .timer {
      Divider()
      typography(c)
    }
  }

  @ViewBuilder private func motionControls(_ c: Clip) -> some View {
    Picker(
      L("动画"),
      selection: Binding(
        get: { e.pathDrawingID == c.id ? .path : c.motion == .slide ? .none : c.motion },
        set: { v in
          if v == .path {
            e.beginPathDrawing(for: c.id)
            return
          }
          e.cancelPathDrawing()
          e.edit(c.id) { clip in
            if clip.motion == .slide { clip.slideFrames = clip.entranceFrames }
            if v == .shake && clip.motion != .shake && clip.shakeFrequency == nil {
              clip.shakeFrequency = 8
            }
            clip.motion = v
            clip.motionPath = nil
          }
        })
    ) {
      let motions: [Motion] = [.none, .shake, .pushIn, .pullOut]
      ForEach(c.length > 1 || c.motion == .path ? motions + [.path] : motions, id: \.self) { motion in
        Text(LKey(motion.rawValue)).tag(motion)
      }
    }
    if e.pathDrawingID == c.id {
      Button(L("取消绘制"), action: e.cancelPathDrawing)
        .buttonStyle(QuietButton())
    } else if c.motion == .path {
      HStack(spacing: 6) {
        Button { e.beginPathDrawing(for: c.id) } label: {
          Label(L("重画路径"), systemImage: "pencil")
        }.buttonStyle(QuietButton()).disabled(c.length <= 1)
        Button { e.previewPath(c) } label: {
          Image(systemName: "play.fill")
        }.buttonStyle(QuietButton()).help(L("试播路径")).accessibilityLabel(L("试播路径"))
      }
    }
    if c.motion == .shake {
      NumberRow(label: L("摇晃幅度"), value: (c.shakeAmplitude ?? 0.018) * 100,
                range: 0...10, unit: "%", precision: 1) { value in
        e.edit(c.id) { $0.shakeAmplitude = value / 100 }
      }
      NumberRow(label: L("摇晃频率"), value: c.shakeFrequency ?? 4 * Double(fps) / Double(c.motionFrames),
                range: 0.1...12, unit: "Hz", precision: 1) { value in
        e.edit(c.id) { $0.shakeFrequency = value }
      }
    }
    if c.motion.isZoom {
      NumberRow(label: L("缩放倍率"), value: c.motionZoom ?? 1.22, range: 1...3, unit: "×", precision: 2) {
        value in e.edit(c.id) { $0.motionZoom = value }
      }
    }
    if c.motion == .shake || c.motion.isZoom {
      Toggle(
        L("一直有效"),
        isOn: Binding(
          get: { c.motionContinuous == true },
          set: { v in e.edit(c.id) { $0.motionContinuous = v } }))
      if c.motion.isZoom || c.motionContinuous != true || c.shakeFrequency == nil {
        NumberRow(
          label: c.motionContinuous == true ? L("循环时长") : L("动画时长"),
          value: Double(c.motionFrames) / 30,
          range: 1.0 / 30...10, unit: L("秒"),
          precision: 2
        ) { v in e.edit(c.id) { $0.motionFrames = max(1, Int((v * 30).rounded())) } }
      }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(L("属性")).font(.headline).padding(.horizontal, 14).frame(height: 40)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          if let tool = e.regionTool {
            Label(tool.title, systemImage: tool.icon).font(.headline).foregroundStyle(UI.color(tool))
            Text(L("选择形状后，在画布上拖出范围。")).font(.caption).foregroundStyle(UI.muted)
            shapePicker($e.drawShape)
          } else if let target = e.selectedTransition, let effect = e.p.transitionEffect(target) {
            TransitionProperties(editor: e, target: target, effect: effect)
          } else if e.selectedIDs.count > 1 {
            Text(e.isWholeGroupSelected ? L("素材组 · \(e.selectedIDs.count) 个片段") : L("已选 \(e.selectedIDs.count) 个片段"))
              .font(.headline)
            if e.canGroup { Button(L("编组"), action: e.groupSelection) }
            if e.canUngroup { Button(L("取消编组"), action: e.ungroupSelection) }
            mediaTiming(e.selectedClips)
            Button(L("在播放头分割"), action: e.split).help(L("在播放头分割所选片段"))
            Button(L("删除所选片段"), action: e.remove)
          } else if let current = e.clip, e.selectedIDs.count == 1 {
            details(current)
          } else {
            Image(systemName: "slider.horizontal.3").font(.system(size: 22, weight: .light))
              .foregroundStyle(UI.muted)
            Text(L("选择时间线上的片段")).fontWeight(.medium)
            Text(L("在这里调整时间、位置和效果。")).foregroundStyle(UI.muted).font(.caption)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true).padding(14)
      }
    }.background(UI.panel)
  }
}

private struct RegionShapePicker: View {
  @Binding var selection: RegionShape

  var body: some View {
    HStack(spacing: 3) {
      ForEach(RegionShape.allCases, id: \.self) { shape in
        let selected = selection == shape
        Button { selection = shape } label: {
          VStack(spacing: 4) {
            Image(systemName: symbol(shape)).font(.system(size: 13, weight: .medium))
            Text(LKey(shape.rawValue)).font(.system(size: 10, weight: .medium))
              .lineLimit(1).minimumScaleFactor(0.8)
          }.frame(maxWidth: .infinity).frame(height: 35)
            .foregroundStyle(selected ? UI.deep : UI.muted)
            .background(selected ? UI.coral : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
          .accessibilityLabel(LKey(shape.rawValue))
          .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }.padding(3).background(UI.deep, in: RoundedRectangle(cornerRadius: 8))
      .accessibilityElement(children: .contain).accessibilityLabel(L("选区形状"))
  }

  private func symbol(_ shape: RegionShape) -> String {
    switch shape {
    case .rectangle: return "rectangle"
    case .square: return "square"
    case .circle: return "circle"
    }
  }
}

struct TextShadowControls: View {
  let value: TextShadow
  let apply: (TextShadow) -> Void
  private func editing<T>(_ key: WritableKeyPath<TextShadow, T>, _ updated: T) {
    var next = value
    next[keyPath: key] = updated
    apply(next)
  }
  var body: some View {
    Toggle(L("文字阴影"), isOn: Binding(get: { value.enabled }, set: { editing(\.enabled, $0) }))
    if value.enabled {
      ProjectColorPicker(title: L("阴影颜色"), hex: value.color) { editing(\.color, $0) }
      NumberRow(label: L("阴影不透明度"), value: value.opacity * 100, range: 0...100, unit: "%") {
        editing(\.opacity, $0 / 100)
      }
      NumberRow(label: L("阴影模糊"), value: value.blur, range: 0...240, unit: "px", precision: 1) {
        editing(\.blur, $0)
      }
      NumberRow(label: L("阴影水平偏移"), value: value.x, range: -2160...2160, unit: "px", precision: 1) {
        editing(\.x, $0)
      }
      NumberRow(label: L("阴影垂直偏移"), value: value.y, range: -2160...2160, unit: "px", precision: 1) {
        editing(\.y, $0)
      }
    }
  }
}

struct ProjectColorPicker: View {
  let title: String
  let hex: String
  let apply: (String) -> Void
  var body: some View {
    ColorPicker(
      title,
      selection: Binding(
        get: { Color(cgColor: ink(hex)) },
        set: { value in
          guard let tint = NSColor(value).usingColorSpace(.sRGB) else { return }
          apply(
            String(
              format: "#%02X%02X%02X", Int((tint.redComponent * 255).rounded()),
              Int((tint.greenComponent * 255).rounded()), Int((tint.blueComponent * 255).rounded()))
          )
        }), supportsOpacity: false)
  }
}
