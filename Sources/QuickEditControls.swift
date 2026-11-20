import SwiftUI

struct QuickTextField: View {
  let label: String
  let value: String
  let apply: (String) -> Void
  @State private var buffer = ""
  @FocusState private var focused: Bool

  var body: some View {
    TextField(label, text: $buffer, prompt: Text(label))
      .textFieldStyle(.roundedBorder)
      .accessibilityLabel(label)
      .focused($focused)
      .onAppear { buffer = value }
      .onChange(of: value) { _, next in if !focused { buffer = next } }
      .onChange(of: focused) { _, active in if !active { commit() } }
      .onSubmit(commit)
  }

  private func commit() {
    if buffer != value { apply(buffer) }
  }
}

struct EditorialControls: View {
  private enum Page: CaseIterable {
    case content, style, motion
    var title: String {
      switch self {
      case .content: return L("内容")
      case .style: return L("样式")
      case .motion: return L("动画")
      }
    }
  }

  let editor: Editor
  let clip: Clip
  let spec: EditorialSpec
  @State private var page = Page.content
  private var cards: EditorialCardsAppearance { spec.cardsAppearance ?? EditorialCardsAppearance() }
  private var metric: EditorialMetricAppearance { spec.metricAppearance ?? EditorialMetricAppearance() }
  private var reveal: MetricReveal? { spec.activeMetricReveal }

  var body: some View {
    if spec.style == .chapter {
      heading
      subtitle
      scrim
      entry
    } else {
      PanelSegments(title: L("组件属性"), options: Page.allCases, selection: $page, tint: UI.mint) { $0.title }
      switch page {
      case .content: content
      case .style: appearance
      case .motion: motion
      }
    }
    Divider()
  }

  private var heading: some View {
    QuickTextField(label: L("标题"), value: clip.text) { text in
      editor.edit(clip.id) { $0.text = text }
    }
  }

  private var subtitle: some View {
    QuickTextField(label: L("副标题"), value: spec.subtitle) { value in update { $0.subtitle = value } }
  }

  @ViewBuilder private var content: some View {
    heading
    if spec.style == .cards {
      Button { editor.editEditorialCards(clip) } label: {
        Label(L("编辑三张卡片…"), systemImage: "square.and.pencil")
          .frame(maxWidth: .infinity, alignment: .leading)
      }.buttonStyle(QuietButton())
    } else {
      subtitle
      if let reveal {
        PanelSegments(title: L("揭晓方式"), options: MetricRevealMode.allCases, selection: Binding(
          get: { reveal.mode }, set: { mode in update { $0.metricReveal?.mode = mode } }
        ), tint: UI.mint) { $0.title }
      }
      if reveal?.mode != .share {
        NumberRow(label: reveal == nil ? L("起始数值") : L("对比数值"), value: metric.start,
                  range: -1e12...1e12, unit: "", precision: spec.decimals, fieldWidth: 121) { value in
          editMetric { $0.start = value }
        }
      }
      NumberRow(label: L("目标数值"), value: spec.value, range: -1e12...1e12, unit: "",
                precision: spec.decimals, fieldWidth: 121) { value in update { $0.value = value } }
      NumberRow(label: L("小数位"), value: Double(spec.decimals), range: 0...3, unit: "") { value in
        update { $0.decimals = Int(value.rounded()) }
      }
      QuickTextField(label: L("数字前缀"), value: spec.prefix) { value in update { $0.prefix = value } }
      QuickTextField(label: L("数字单位"), value: spec.suffix) { value in update { $0.suffix = value } }
      Toggle(L("千位分隔符"), isOn: Binding(get: { metric.groupsDigits }, set: { value in
        editMetric { $0.groupsDigits = value }
      }))
      Toggle(L("显示正号"), isOn: Binding(get: { metric.showsPlus }, set: { value in
        editMetric { $0.showsPlus = value }
      }))
    }
  }

  @ViewBuilder private var appearance: some View {
    if spec.style == .cards {
      SectionName(name: L("版式"))
      PanelSegments(title: L("版式"), options: EditorialCardLayout.allCases, selection: Binding(
        get: { cards.layout }, set: { value in editCards { $0.layout = value } }
      ), tint: UI.mint) { $0.title }
      NumberRow(label: L("说明字号"), value: cards.detailSize, range: 12...25, unit: "pt") { value in
        editCards { $0.detailSize = value }
      }
      NumberRow(label: L("卡片间距"), value: cards.gap, range: 4...26, unit: "pt") { value in editCards { $0.gap = value } }
      NumberRow(label: L("卡片圆角"), value: cards.corner, range: 0...30, unit: "pt") { value in
        editCards { $0.corner = value }
      }
      SectionName(name: L("重点卡片"))
      MenuField(title: L("重点卡片"), choices: [L("无")] + spec.cards.indices.map { L("卡片 \($0 + 1)") },
                selectedIndex: cards.featured.map { $0 + 1 } ?? 0) { index in
        editCards { $0.featured = index == 0 ? nil : index - 1 }
      }.frame(height: 23)
    } else {
      PanelSegments(title: L("数字样式"), options: [false, true], selection: Binding(
        get: { reveal != nil }, set: selectReveal
      ), tint: UI.mint) { $0 ? L("数字揭晓") : L("经典数字") }
      if let reveal {
        NumberRow(label: L("比例条上限"), value: reveal.scale, range: 0.001...1e12, unit: "",
                  precision: spec.decimals, fieldWidth: 113) { value in
          update { $0.metricReveal?.scale = value }
        }.help(L("数值超过参考上限时，比例条会扩展刻度。"))
      }
      SectionName(name: L("数字字体"))
      MenuField(title: L("数字字体"), choices: [metric.font.isEmpty ? L("系统字体") : metric.font],
                selectedIndex: 0, loadChoices: { [L("系统字体")] + CaptionPanel.families }) { index in
        editMetric { $0.font = index == 0 ? "" : CaptionPanel.families[index - 1] }
      }.frame(height: 23)
      NumberRow(label: L("数字大小"), value: metric.size * 100, range: 55...145, unit: "%") { value in
        editMetric { $0.size = value / 100 }
      }
      NumberRow(label: L("单位大小"), value: metric.unitSize * 100, range: 35...100, unit: "%") { value in
        editMetric { $0.unitSize = value / 100 }
      }
    }
    scrim
  }

  @ViewBuilder private var motion: some View {
    if let reveal {
      let offset = reveal.offsetFrames
      NumberRow(label: L("揭晓位置"), value: Double(offset) / Double(fps),
                range: Double(min(0, offset)) / Double(fps)...Double(max(clip.length - 1, offset)) / Double(fps),
                unit: L("秒"), precision: 2) { value in
        update { $0.metricReveal?.offsetFrames = frames(value) }
      }.help(L("从片段开头算起。"))
      Button {
        editor.alignMetricRevealToPlayhead(clip.id)
      } label: {
        Label(L("对齐到播放头"), systemImage: "scope")
          .frame(maxWidth: .infinity, alignment: .leading)
      }.buttonStyle(QuietButton())
        .help(L("将播放头移到口播重音，再点这里对齐。"))
      NumberRow(label: L("揭晓时长"), value: Double(reveal.durationFrames) / Double(fps),
                range: durationRange(reveal.durationFrames), unit: L("秒"), precision: 2) { value in
        update { $0.metricReveal?.durationFrames = frames(value) }
      }.help(L("设为 0 秒时在揭晓位置直接亮起。"))
    } else {
      entry
    }
    NumberRow(label: L("出场时长"), value: Double(spec.exitFrames ?? 0) / Double(fps),
              range: durationRange(spec.exitFrames ?? 0), unit: L("秒"), precision: 2) { value in
      update { $0.exitFrames = Int((value * Double(fps)).rounded()) }
    }
    if spec.style == .cards {
      NumberRow(label: L("依次间隔"), value: cards.stagger * 100, range: 0...40, unit: "%") { value in
        editCards { $0.stagger = value / 100 }
      }
      .help(L("间隔为 0 时三张卡片同时入场。"))
      Toggle(L("倒序入场"), isOn: Binding(get: { cards.reverse }, set: { value in
        editCards { $0.reverse = value }
      }))
    } else {
      SectionName(name: L("计数节奏"))
      let options = EditorialCounting.allCases
      MenuField(title: L("计数节奏"), choices: options.map(\.title),
                selectedIndex: options.firstIndex(of: metric.counting) ?? 0) { index in
        editMetric { $0.counting = options[index] }
      }.frame(height: 23)
    }
  }

  private var scrim: some View {
    NumberRow(label: L("底片暗度"), value: spec.scrim * 100, range: 0...100, unit: "%") { value in
      update { $0.scrim = value / 100 }
    }
  }

  private var entry: some View {
    NumberRow(label: L("入场时长"), value: Double(spec.entryFrames) / Double(fps),
              range: durationRange(spec.entryFrames), unit: L("秒"), precision: 2) { value in
      update { $0.entryFrames = Int((value * Double(fps)).rounded()) }
    }
  }

  private func durationRange(_ frames: Int) -> ClosedRange<Double> {
    0...Double(max(clip.length - 1, frames)) / Double(fps)
  }

  private func frames(_ seconds: Double) -> Int { Int((seconds * Double(fps)).rounded()) }

  private func selectReveal(_ enabled: Bool) {
    update { $0.useMetricReveal(enabled, clipLength: clip.length) }
  }

  private func editCards(_ action: (inout EditorialCardsAppearance) -> Void) {
    update {
      var style = $0.cardsAppearance ?? EditorialCardsAppearance()
      action(&style)
      $0.cardsAppearance = style
    }
  }

  private func editMetric(_ action: (inout EditorialMetricAppearance) -> Void) {
    update {
      var style = $0.metricAppearance ?? EditorialMetricAppearance()
      action(&style)
      $0.metricAppearance = style
    }
  }

  private func update(_ action: (inout EditorialSpec) -> Void) {
    editor.edit(clip.id) { clip in
      guard var spec = clip.editorial else { return }
      action(&spec)
      clip.editorial = spec
    }
  }
}

struct PictureInsetControls: View {
  let editor: Editor
  let clip: Clip
  let inset: PictureInset
  private var cornerIndex: Int {
    let canvas = editor.p.canvas.size(540)
    let height = min(canvas.width, canvas.height) * clip.displayScale
    let match = InsetCorner.allCases.firstIndex { corner in
      let p = corner.center(canvas: canvas, height: height, aspect: inset.shape.aspect)
      return abs(p.x - clip.x) + abs(p.y - clip.y) < 0.0001
    }
    return match.map { $0 + 1 } ?? 0
  }

  var body: some View {
    SectionName(name: L("画中画"))
    PanelSegments(title: L("形状"), options: InsetShape.allCases, selection: Binding(
      get: { inset.shape }, set: { shape in editor.edit(clip.id) { $0.pictureInset?.shape = shape } }
    ), tint: UI.mint) { $0.title }
    MenuField(title: L("画中画位置"), choices: [L("放到画布角落")] + InsetCorner.allCases.map(\.title),
              selectedIndex: cornerIndex) { index in
      guard index > 0 else { return }
      let corner = InsetCorner.allCases[index - 1]
      let size = editor.p.canvas.size(540)
      editor.edit(clip.id) { $0.placePictureInset(corner, canvas: size) }
    }.frame(height: 22)
    Button(L("移除画中画")) { editor.edit(clip.id) { $0.removePictureInset() } }
      .buttonStyle(QuietButton())
    Divider()
  }
}
