import SwiftUI

struct ChartDataEditor: View {
  let chart: ChartSpec
  let cancel: () -> Void
  let apply: (ChartSpec) -> Void
  @State private var title: String
  @State private var xTitle: String
  @State private var yTitle: String
  @State private var csv: String
  @State private var error: String?

  init(chart: ChartSpec, cancel: @escaping () -> Void, apply: @escaping (ChartSpec) -> Void) {
    self.chart = chart
    self.cancel = cancel
    self.apply = apply
    _title = State(initialValue: chart.title)
    _xTitle = State(initialValue: chart.xTitle)
    _yTitle = State(initialValue: chart.yTitle)
    _csv = State(initialValue: chart.editableRows)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(chart.kind.title, systemImage: chart.kind.icon).font(.headline).foregroundStyle(UI.mint)
      TextField(L("图表标题"), text: $title, prompt: Text(chart.kind.title))
        .textFieldStyle(.roundedBorder)
      if chart.kind != .pie {
        HStack(spacing: 10) {
          axisTitle(L("横轴标题"), text: $xTitle)
          axisTitle(L("纵轴标题"), text: $yTitle)
        }
      }
      Text(chart.kind == .scatter
        ? L("每行用逗号分隔 X、Y 和可选的点标签。")
        : L("每行用逗号分隔分类标签和数值。"))
        .font(.caption).foregroundStyle(UI.muted)
      TextEditor(text: $csv).font(.system(.body, design: .monospaced))
        .autocorrectionDisabled()
        .scrollContentBackground(.hidden)
        .padding(6)
        .background(UI.deep, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityLabel(L("图表 CSV 数据"))
      if let error { Text(error).font(.caption).foregroundStyle(UI.coral) }
      HStack {
        Spacer()
        Button(L("取消"), action: cancel).buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
        Button(L("应用数据"), action: save).buttonStyle(PrimaryButton(tint: UI.mint))
      }
    }.padding(15).background(UI.panel).foregroundStyle(.white).preferredColorScheme(.dark)
  }

  private func axisTitle(_ label: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).font(.caption).foregroundStyle(UI.muted)
      TextField(label, text: text, prompt: Text(L("可留空")))
        .textFieldStyle(.roundedBorder)
    }
  }

  private func save() {
    do {
      var next = try chart.replacingData(from: csv, header: false)
      next.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
      next.xTitle = xTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      next.yTitle = yTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      apply(next)
    } catch { self.error = error.localizedDescription }
  }
}
