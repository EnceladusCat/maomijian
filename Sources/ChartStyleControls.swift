import SwiftUI

struct ChartStyleControls: View {
  let clip: Clip
  let kind: ChartKind
  let editor: Editor
  @State private var expanded = false

  private var style: ChartAppearance { clip.chartAppearance ?? ChartAppearance() }

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 9) {
        PanelSegments(title: L("主题"), options: ChartTheme.allCases, selection: binding(\.theme),
                      tint: UI.mint) { $0.title }
        if style.theme != .transparent {
          NumberRow(label: L("背景不透明度"), value: style.backgroundOpacity * 100,
                    range: 0...100, unit: "%") {
            binding(\.backgroundOpacity).wrappedValue = $0 / 100
          }
        }
        SectionName(name: L("图表配色"))
        let mode = Binding(
          get: { style.paletteMode(kind) }, set: { binding(\.colorMode).wrappedValue = $0 }
        )
        PanelSegments(title: L("统一与分类配色"), options: [.single, .category],
                      selection: mode, tint: UI.mint) { $0.title }
        PanelSegments(title: L("按数值配色"), options: kind == .bar ? [.rank, .magnitude, .sign] : [.rank, .magnitude],
                      selection: mode, tint: UI.mint) { $0.title }
        if mode.wrappedValue == .sign {
          ProjectColorPicker(title: L("负值色"), hex: style.lowColor) { binding(\.lowColor).wrappedValue = $0 }
        }
        if mode.wrappedValue.isGradient {
          ProjectColorPicker(title: L("低值色"), hex: style.lowColor) { binding(\.lowColor).wrappedValue = $0 }
        }
        ProjectColorPicker(title: mode.wrappedValue == .sign ? L("正值色")
                           : mode.wrappedValue.isGradient ? L("高值色") : L("主色"), hex: clip.color) { color in
          editor.edit(clip.id) { $0.color = color }
        }
        if kind == .pie {
          NumberRow(label: L("中心镂空"), value: style.pieHole * 100, range: 0...72, unit: "%") {
            binding(\.pieHole).wrappedValue = $0 / 100
          }
        } else {
          NumberRow(label: markSizeLabel, value: style.markSize * 100, range: 35...200, unit: "%") {
            binding(\.markSize).wrappedValue = $0 / 100
          }
        }
        Divider()
        Toggle(L("显示标题"), isOn: binding(\.showsTitle))
        Toggle(kind == .pie ? L("显示分类图例") : L("显示坐标轴标签"), isOn: binding(\.showsLabels))
        Toggle(kind == .pie ? L("显示百分比") : L("显示数据值"), isOn: Binding(
          get: { style.displaysValues(kind) },
          set: { binding(\.showsValues).wrappedValue = $0 }
        ))
        if kind != .pie {
          Toggle(L("显示网格线"), isOn: binding(\.showsGrid))
          if kind == .line {
            Toggle(L("线下填色"), isOn: Binding(
              get: { style.areaFill == true }, set: { binding(\.areaFill).wrappedValue = $0 }))
          }
          if let chart = clip.chart { chartMarker(chart) }
        }
        MenuField(title: L("字体"), choices: [style.font.isEmpty ? L("系统字体") : style.font],
                  selectedIndex: 0, loadChoices: { [L("系统字体")] + CaptionPanel.families }) { index in
          binding(\.font).wrappedValue = index == 0 ? "" : CaptionPanel.families[index - 1]
        }.frame(height: 22)
        NumberRow(label: L("文字大小"), value: style.fontScale * 100, range: 60...150, unit: "%") {
          binding(\.fontScale).wrappedValue = $0 / 100
        }
        ProjectColorPicker(title: L("文字颜色"), hex: style.textColor ?? defaultTextColor) {
          binding(\.textColor).wrappedValue = $0
        }
        if style.textColor != nil {
          Button(L("恢复主题文字颜色")) { binding(\.textColor).wrappedValue = nil }.buttonStyle(.plain)
            .font(.caption).foregroundStyle(UI.mint)
        }
      }.padding(.top, 8)
    } label: {
      Label(L("图表样式"), systemImage: "slider.horizontal.3").font(.callout)
    }.disclosureGroupStyle(SettingsDisclosureStyle())
  }

  private var defaultTextColor: String { style.theme == .light ? "#182438" : "#F1F5FF" }
  @ViewBuilder private func chartMarker(_ chart: ChartSpec) -> some View {
    Toggle(L("标出关键节点"), isOn: Binding(
      get: { chart.marker != nil }, set: { enabled in
        editor.edit(clip.id) { $0.chart?.marker = enabled ? ChartMarker(row: chart.points.count - 1) : nil }
      }))
    if let marker = chart.marker {
      NumberRow(label: L("数据行"), value: Double(marker.row + 1),
                range: 1...Double(chart.points.count), unit: "") { value in
        editor.edit(clip.id) { $0.chart?.marker?.row = Int(value.rounded()) - 1 }
      }
      QuickTextField(label: L("节点说明"), value: marker.title) { value in
        editor.edit(clip.id) { $0.chart?.marker?.title = value }
      }.id(clip.id)
    }
  }
  private var markSizeLabel: String {
    switch kind {
    case .bar: return L("柱宽")
    case .line: return L("线宽")
    case .scatter: return L("散点大小")
    case .pie: return L("中心镂空")
    }
  }

  private func binding<T>(_ key: WritableKeyPath<ChartAppearance, T>) -> Binding<T> {
    Binding(get: { style[keyPath: key] }, set: { value in
      editor.edit(clip.id) { clip in
        var appearance = clip.chartAppearance ?? ChartAppearance()
        appearance[keyPath: key] = value
        clip.chartAppearance = appearance
      }
    })
  }
}
