import SwiftUI

struct AudioVisualizationControls: View {
  let editor: Editor
  let clip: Clip
  let visual: AudioVisualization

  var body: some View {
    PanelSegments(title: L("可视化样式"), options: AudioVisualStyle.allCases,
                  selection: binding(\.style), tint: UI.mint) { $0.title }
    let sources = editor.p.audioVisualSources()
    if !sources.isEmpty {
      let names = [L("选择音源")] + sources.map { "\($0.name) · \(tc($0.span.lowerBound))" }
      let index = sources.firstIndex { $0.id == visual.source }.map { $0 + 1 } ?? 0
      MenuField(title: L("音源"), choices: names, selectedIndex: index) { chosen in
        guard chosen > 0 && chosen <= sources.count else { return }
        let id = sources[chosen - 1].id
        editor.change { $0.linkAudioVisualization(clip.id, to: id) }
      }.frame(height: 22)
    }
    if visual.source == nil {
      Text(L("请选择时间线上的音源")).font(.caption).foregroundStyle(UI.muted)
    }
    Toggle(L("跟随素材时间"), isOn: binding(\.followsSource)).disabled(visual.source == nil)
    NumberRow(label: L("采样窗口"), value: visual.seconds, range: 0.3...6, unit: L("秒"), precision: 1) {
      binding(\.seconds).wrappedValue = $0
    }
    NumberRow(label: L("灵敏度"), value: visual.gain, range: 0.1...6, unit: "×", precision: 1) {
      binding(\.gain).wrappedValue = $0
    }
    NumberRow(label: visual.style == .area ? L("采样点") : L("柱形数量"),
              value: Double(visual.points), range: 12...96, unit: "") {
      binding(\.points).wrappedValue = Int($0.rounded())
    }
    ProjectColorPicker(title: L("起点色"), hex: visual.secondaryColor) {
      binding(\.secondaryColor).wrappedValue = $0
    }
    ProjectColorPicker(title: L("终点色"), hex: clip.color) { color in
      editor.edit(clip.id) { $0.color = color }
    }
    Divider()
  }

  private func binding<T>(_ key: WritableKeyPath<AudioVisualization, T>) -> Binding<T> {
    Binding(get: { visual[keyPath: key] }, set: { value in
      editor.edit(clip.id) { $0.audioVisualization?[keyPath: key] = value }
    })
  }
}
