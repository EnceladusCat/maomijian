import SwiftUI

struct NumberRow: View {
  let label: String, value: Double, range: ClosedRange<Double>, unit: String
  var precision = 0
  var mixed = false
  let done: (Double) -> Void
  var body: some View { NumericControl(row: self).frame(height: 21) }
  var formatted: String { mixed ? "" : String(format: "%.*f", precision, value) }
}
private struct NumericControl: NSViewRepresentable {
  let row: NumberRow
  func makeNSView(context: Context) -> FieldRow { FieldRow() }
  func updateNSView(_ view: FieldRow, context: Context) { view.configure(row) }
  final class FieldRow: NSView, NSTextFieldDelegate {
    let label = NSTextField(labelWithString: ""), field = NSTextField(),
      unit = NSTextField(labelWithString: "")
    var row: NumberRow?
    override init(frame: NSRect) {
      super.init(frame: frame)
      for text in [label, unit] {
        text.font = .systemFont(ofSize: 12)
        text.textColor = NSColor(UI.muted)
        addSubview(text)
      }
      field.alignment = .right
      field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
      field.delegate = self
      addSubview(field)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
      super.layout()
      let unitWidth = max(12, unit.intrinsicContentSize.width)
      let x = max(0, bounds.width - unitWidth - 69)
      label.frame = NSRect(x: 0, y: 2, width: max(0, x - 4), height: 17)
      field.frame = NSRect(x: x, y: 0, width: 65, height: 21)
      unit.frame = NSRect(x: x + 69, y: 2, width: unitWidth, height: 17)
    }
    func configure(_ next: NumberRow) {
      let previous = row
      row = next
      if label.stringValue != next.label {
        label.stringValue = next.label
        field.setAccessibilityLabel(next.label)
      }
      if unit.stringValue != next.unit {
        unit.stringValue = next.unit
        needsLayout = true
      }
      field.placeholderString = next.mixed ? "混合" : nil
      if previous?.value != next.value || previous?.mixed != next.mixed
        || field.currentEditor() == nil
      {
        if field.stringValue != next.formatted { field.stringValue = next.formatted }
      }
    }
    func controlTextDidEndEditing(_ notification: Notification) {
      guard let row else { return }
      let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard text != row.formatted, let number = Double(text), number.isFinite else {
        field.stringValue = row.formatted
        return
      }
      let value = bound(number, row.range.lowerBound, row.range.upperBound)
      field.stringValue = String(format: "%.*f", row.precision, value)
      if row.mixed || abs(row.value - value) > 1e-8 { row.done(value) }
    }
  }
}
private struct Writing: View {
  let value: String, apply: (String) -> Void
  @State private var buffer = ""
  @FocusState private var focused: Bool
  var body: some View {
    TextEditor(text: $buffer).focused($focused).font(.body).frame(minHeight: 52).padding(3)
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
  @State private var lastClip = Clip.annotation(.arrow, at: 0)
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
    Picker("选区形状", selection: selection) {
      ForEach(RegionShape.allCases, id: \.self) { v in Text(v.rawValue).tag(v) }
    }.pickerStyle(.segmented)
  }
  @ViewBuilder func mediaTiming(_ clips: [Clip]) -> some View {
    if let first = clips.first,
      clips.allSatisfy({ $0.kind.isMedia && e.p.asset($0.asset)?.isStill != true })
    {
      let ids = Set(clips.map(\.id))
      NumberRow(
        label: "播放倍速", value: first.rate, range: 0.25...4, unit: "×", precision: 2,
        mixed: clips.contains { $0.rate != first.rate }
      ) { e.adjustMedia(ids, rate: $0) }
      if clips.allSatisfy({ e.p.asset($0.asset)?.audio == true }) {
        NumberRow(
          label: "音高", value: first.pitch, range: -12...12, unit: "半音", precision: 1,
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
    SectionName(name: "变换")
    NumberRow(label: "素材缩放", value: c.displayScale * 100, range: 5...800, unit: "%") { v in
      e.edit(c.id) { $0.visualScale = v / 100 }
    }
    HStack {
      Tool(symbol: "rotate.left", label: "向左旋转 90°") {
        e.edit(c.id) { $0.angle = ($0.angle - 90).truncatingRemainder(dividingBy: 360) }
      }
      Tool(symbol: "rotate.right", label: "向右旋转 90°") {
        e.edit(c.id) { $0.angle = ($0.angle + 90).truncatingRemainder(dividingBy: 360) }
      }
      num("角度", c, \.angle, 1, -360...360, "°", 1)
    }
    num("水平位置", c, \.x, 100, -400...500, "%", 1)
    num("垂直位置", c, \.y, 100, -400...500, "%", 1)
    num("不透明度", c, \.opacity, 100, 0...100, "%")
    HStack {
      Button(e.cropID == c.id && e.selected == c.id ? "完成裁剪" : "裁剪素材") { e.beginCrop(c) }
      if c.sourceCrop != nil { Button("重置裁剪") { e.edit(c.id) { $0.sourceCrop = nil } } }
    }
    if e.cropID == c.id && e.selected == c.id {
      let crop = c.sourceCrop ?? SourceCrop()
      ForEach(0..<4, id: \.self) { edge in
        let title = ["裁左", "裁上", "裁右", "裁下"][edge]
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
    Picker("边框", selection: borderStyle(c)) {
      ForEach(CaptionBorder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
    }
    if let border = c.visualBorder, border.style != .none {
      NumberRow(label: "边框宽度", value: border.width, range: 1...64, unit: "px") { value in
        e.edit(c.id) { $0.visualBorder?.width = value }
      }
      colorControl("边框颜色", border.color) { color in e.edit(c.id) { $0.visualBorder?.color = color }
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
  @ViewBuilder private func typography(_ c: Clip) -> some View {
    let appearance = c.textAppearance ?? TextAppearance()
    let fonts = [""] + CaptionPanel.families
    SectionName(name: "文字样式")
    MenuField(
      title: "字体", choices: ["系统字体"] + CaptionPanel.families,
      selectedIndex: fonts.firstIndex(of: appearance.font) ?? 0
    ) {
      textBinding(c, \.font).wrappedValue = fonts[$0]
    }.frame(height: 21)
    NumberRow(label: "字号", value: appearance.size, range: 8...240, unit: "px") {
      textBinding(c, \.size).wrappedValue = $0
    }
    Toggle("粗体", isOn: textBinding(c, \.bold))
    Picker("描边", selection: textBinding(c, \.outline.style)) {
      ForEach(CaptionBorder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
    }
    if appearance.outline.style != .none {
      NumberRow(label: "描边宽度", value: appearance.outline.width, range: 1...64, unit: "px") {
        textBinding(c, \.outline.width).wrappedValue = $0
      }
      colorControl("描边颜色", appearance.outline.color) {
        textBinding(c, \.outline.color).wrappedValue = $0
      }
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
    SectionName(name: "计时设置")
    Picker(
      "模式",
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
      ForEach(TimerDirection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
    }
    NumberRow(label: "起始值", value: timer.initialSeconds, range: 0...86400, unit: "秒", precision: 1)
    {
      timerBinding(c, \.initialSeconds).wrappedValue = $0
    }
    if timer.direction == .custom {
      NumberRow(label: "流速", value: timer.speed, range: -100...100, unit: "×", precision: 2) {
        timerBinding(c, \.speed).wrappedValue = $0
      }
    }
    Picker("格式", selection: timerBinding(c, \.format)) {
      ForEach(TimerFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
    }
    TextField("前缀单位", text: timerBinding(c, \.prefix)).accessibilityLabel("前缀单位")
    TextField("后缀单位", text: timerBinding(c, \.suffix)).accessibilityLabel("后缀单位")
  }
  @ViewBuilder func details(_ c: Clip) -> some View {
    Label(e.p.asset(c.asset)?.isStill == true ? "图片" : c.kind.title, systemImage: c.kind.icon).font(
      .headline
    ).foregroundStyle(UI.color(c.kind))
    if c.kind.isRegion {
      Text("拖动选框调整位置，拉四角改变范围。").font(.caption).foregroundStyle(UI.muted)
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
        colorControl("边框颜色", c.border) { hex in e.edit(c.id) { $0.borderColor = hex } }
        num("放大倍率", c, \.scale, 1, 1...5, "×", 2)
        NumberRow(
          label: "进入时长", value: Double(c.entryFrames) / 30, range: 0...Double(c.length) / 30,
          unit: "秒", precision: 2
        ) { v in
          e.edit(c.id) { $0.zoomInFrames = Int((v * 30).rounded()) }
        }
        NumberRow(
          label: "退出时长", value: Double(c.exitFrames) / 30, range: 0...Double(c.length) / 30,
          unit: "秒", precision: 2
        ) { v in
          e.edit(c.id) { $0.zoomOutFrames = Int((v * 30).rounded()) }
        }
        if c.entryFrames + c.exitFrames > c.length - 1 {
          Text("片段较短，进出时长会按比例缩短。").font(.caption).foregroundStyle(UI.muted)
        }
      } else {
        num("框外暗度", c, \.opacity, 100, 0...100, "%")
      }
      if c.shape == .rectangle {
        num("区域宽度", c, \.w, 100, 1...100, "%")
        num("区域高度", c, \.h, 100, 1...100, "%")
      } else {
        let size = e.p.canvas.size(540)
        let box = c.shape.fit(c.region, in: size)
        let short = min(size.width, size.height)
        NumberRow(
          label: c.shape == .circle ? "直径" : "边长",
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
      label: "开始时间", value: Double(c.start) / 30, range: 0...Double(maxFrames - c.length) / 30,
      unit: "秒", precision: 3
    ) { e.move(c, by: Int(($0 * 30).rounded()) - c.start, edge: 0) }
    let still = e.p.asset(c.asset)?.isStill == true
    let maxLength =
      still
      ? maxFrames - c.start : c.maximumLength(assetFrames: e.p.asset(c.asset)?.frames ?? maxFrames)
    NumberRow(
      label: "持续时间", value: Double(c.length) / 30, range: 1.0 / 30...Double(maxLength) / 30,
      unit: "秒", precision: 3
    ) { e.move(c, by: Int(($0 * 30).rounded()) - c.length, edge: 1) }
    if c.kind.isMedia && !still {
      mediaTiming([c])
      Text("素材入点  " + tc(c.offset)).font(.caption.monospacedDigit()).foregroundStyle(UI.muted)
      if e.p.asset(c.asset)?.audio == true {
        Divider()
        num("音量", c, \.volume, 100, 0...300, "%")
        if c.kind == .video { Button("分离音频", action: e.detach).disabled(c.volume == 0) }
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
      SectionName(name: "正文")
      Writing(value: c.text) { v in e.edit(c.id) { $0.text = v } }
    }
    if !c.kind.isMedia {
      Divider()
      SectionName(name: c.kind.isRegion ? "选区中心" : "画布位置")
      num("水平", c, \.x, 100, 0...100, "%")
      num("垂直", c, \.y, 100, 0...100, "%")
    }
    if c.kind.isArt && !c.kind.isRegion {
      num("宽度", c, \.w, 100, 1...200, "%")
      num("高度", c, \.h, 100, 1...200, "%")
      num("旋转", c, \.angle, 1, -360...360, "°")
      num("不透明度", c, \.opacity, 100, 0...100, "%")
      if c.kind == .caption {
        Button("全局字幕样式") { e.openTab(.captions) }
      } else {
        colorControl("颜色", c.color) { hex in e.edit(c.id) { $0.color = hex } }
      }
    }
    if c.kind == .text || c.kind == .timer {
      Divider()
      typography(c)
    }
    if c.supportsMotion {
      Divider()
      Picker(
        "动画",
        selection: Binding(
          get: { c.motion == .slide ? .none : c.motion },
          set: { v in
            e.edit(c.id) { clip in
              if clip.motion == .slide { clip.slideFrames = clip.entranceFrames }
              clip.motion = v
            }
          })
      ) {
        ForEach([Motion.none, .shake], id: \.self) { Text($0.rawValue).tag($0) }
      }
      if c.motion == .shake {
        Toggle(
          "一直有效",
          isOn: Binding(
            get: { c.motionContinuous == true },
            set: { v in e.edit(c.id) { $0.motionContinuous = v } }))
        NumberRow(
          label: c.motionContinuous == true ? "循环时长" : "动画时长", value: Double(c.motionFrames) / 30,
          range: 1.0 / 30...10, unit: "秒",
          precision: 2
        ) { v in e.edit(c.id) { $0.motionFrames = max(1, Int((v * 30).rounded())) } }
      }
    }

  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("属性").font(.headline).padding(.horizontal, 14).frame(height: 40)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          let single = e.regionTool == nil && e.selectedIDs.count == 1 && e.clip != nil
          ZStack(alignment: .topLeading) {
            let current = single ? (e.clip ?? lastClip) : lastClip
            VStack(alignment: .leading, spacing: 9) { details(current) }
              .frame(maxWidth: .infinity, alignment: .leading)
              .opacity(single ? 1 : 0).allowsHitTesting(single).accessibilityHidden(!single)
              .frame(height: single ? nil : 0, alignment: .top).clipped()
            VStack(alignment: .leading, spacing: 10) {
              if let tool = e.regionTool {
                Text(tool.title).font(.headline)
                shapePicker($e.drawShape)
                Text("选择形状后，在画布上拖出范围。").font(.caption).foregroundStyle(UI.muted)
              } else if e.selectedIDs.count > 1 {
                Text("已选 \(e.selectedIDs.count) 个片段").font(.headline)
                mediaTiming(e.selectedClips)
                Button("在播放头分割所选片段", action: e.split)
                Button("删除所选片段", action: e.remove)
              } else if !single {
                Image(systemName: "slider.horizontal.3").font(.system(size: 22, weight: .light))
                  .foregroundStyle(UI.muted)
                Text("选择时间线上的片段").fontWeight(.medium)
                Text("在这里调整时间、位置和效果。").foregroundStyle(UI.muted).font(.caption)
              }
            }
          }.onChange(of: e.clip) { if let c = $0 { lastClip = c } }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
      }
    }.background(UI.panel)
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
