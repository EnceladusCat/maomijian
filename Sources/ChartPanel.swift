import SwiftUI
import UniformTypeIdentifiers

struct ChartPanel: View {
  let editor: Editor
  @ObservedObject var updates: PanelUpdates
  @State private var kind = ChartKind.bar
  @State private var csv: ChartCSV?
  @State private var embedded: ChartSpec?
  @State private var header = true
  @State private var x = 0
  @State private var y = 1
  @State private var title = ""
  @State private var preview: ChartLayout?
  @State private var previewProgress = 1.0
  @State private var draft: ChartSpec?
  @State private var skipped = 0
  @State private var isLoading = false
  @State private var error: String?
  @State private var request = UUID()
  private var selected: Clip? { editor.clip.flatMap { $0.kind == .chart ? $0 : nil } }
  private var style: ChartAppearance? { selected?.chartAppearance }
  private var accent: String { selected?.color ?? "#8CE2C1" }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 11) {
          HStack {
            SectionName(name: L("图表"))
            Spacer(minLength: 4)
            Button(action: openCSV) {
              Label(L("导入 CSV"), systemImage: "arrow.down.document")
            }.buttonStyle(QuietButton()).disabled(isLoading)
          }
          LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible())], spacing: 5) {
            ForEach(ChartKind.allCases, id: \.self) { type in
              Button {
                if type != kind {
                  kind = type
                  rebuild()
                }
              } label: {
                Label(type.title, systemImage: type.icon)
                  .font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                  .frame(maxWidth: .infinity, minHeight: 26)
                  .foregroundStyle(type == kind ? UI.mint : UI.muted)
                  .background(type == kind ? UI.mint.opacity(0.15) : UI.deep,
                              in: RoundedRectangle(cornerRadius: 6))
                  .contentShape(Rectangle())
              }.buttonStyle(.plain)
                .accessibilityAddTraits(type == kind ? .isSelected : [])
            }
          }
          if let csv {
            source(csv.name)
            Toggle(L("首行为表头"), isOn: $header).font(.caption).onChange(of: header) { _, _ in rebuild() }
            let names = csv.columns(header: header)
            column(kind == .scatter ? L("横轴数值") : L("分类标签"), names, x) {
              x = $0
              rebuild()
            }
            column(L("数值列"), names, y) {
              y = $0
              rebuild()
            }
          } else {
            source(embedded == nil ? L("示例数据") : L("片段内数据"))
          }
          if let error { Text(error).font(.caption).foregroundStyle(UI.coral) }
          if isLoading { ProgressView().controlSize(.small).accessibilityLabel(L("正在读取 CSV")) }
          TextField(L("图表标题"), text: $title, prompt: Text(kind.title))
            .textFieldStyle(.roundedBorder).accessibilityLabel(L("图表标题"))
            .onChange(of: title) { _, _ in rebuild() }
          ZStack(alignment: .bottomTrailing) {
            if let preview {
              ChartThumbnail(layout: preview, progress: previewProgress)
                .frame(height: 109)
                .accessibilityLabel(L("图表预览"))
              Button {
                previewProgress = 0
                DispatchQueue.main.async {
                  withAnimation(.easeInOut(duration: 0.75)) { previewProgress = 1 }
                }
              } label: {
                Image(systemName: "arrow.counterclockwise").padding(6)
              }.buttonStyle(.plain).background(UI.deep, in: Circle()).padding(4)
                .accessibilityLabel(L("重播图表动画")).help(L("重播图表动画"))
            } else {
              Text(L("没有可绘制的数据")).font(.caption).foregroundStyle(UI.muted)
                .frame(maxWidth: .infinity).frame(height: 61)
                .background(UI.deep, in: RoundedRectangle(cornerRadius: 8))
            }
          }
          if let draft {
            let count = draft.points.count
            Text(skipped == 0 ? L("\(count) 条数据") : L("\(count) 条数据 · 跳过 \(skipped) 行"))
              .font(.caption).foregroundStyle(UI.muted)
          } else if skipped > 0 {
            Text(L("跳过 \(skipped) 行")).font(.caption).foregroundStyle(UI.muted)
          }
        }.padding(10)
      }
      VStack(spacing: 5) {
        if let selected, let chart = selected.chart, let draft, hasChanges(from: chart, to: draft) {
          Button(L("更新选中图表")) { insert(replace: selected) }
            .buttonStyle(QuietButton()).disabled(isLoading)
        }
        Button { insert(replace: nil) } label: {
          Label(L("添加图表到时间线"), systemImage: "plus").frame(maxWidth: .infinity)
        }.buttonStyle(PrimaryButton(tint: UI.mint)).disabled(draft == nil || isLoading)
      }.padding(8).background(UI.panel)
    }
    .onChange(of: selected?.id, initial: true) { _, _ in
      if csv == nil { useSelected() }
      else { rebuild() }
    }
    .onChange(of: style) { _, _ in rebuild() }
    .onChange(of: accent) { _, _ in rebuild() }
    .onChange(of: selected?.chart) { _, chart in
      if csv == nil && embedded != chart { useSelected() }
    }
    .onReceive(editor.shelf.chartDataEdits) { id in
      guard selected?.id == id else { return }
      csv = nil
      useSelected()
    }
  }

  private func column(_ label: String, _ columns: [String], _ value: Int, choose: @escaping (Int) -> Void) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(label).font(.caption).foregroundStyle(UI.muted)
      MenuField(title: label, choices: columns, selectedIndex: value, choose: choose)
        .frame(height: 22)
    }
  }

  private func source(_ name: String) -> some View {
    HStack(spacing: 5) {
      Image(systemName: csv == nil ? "tablecells" : "doc.text")
      Text(name).lineLimit(1).truncationMode(.middle).help(name)
      Spacer(minLength: 0)
      if csv != nil || embedded != nil {
        Button(L("用示例")) {
          csv = nil
          embedded = nil
          error = nil
          title = ""
          rebuild()
        }.buttonStyle(.plain).foregroundStyle(UI.mint)
      }
    }.font(.caption).foregroundStyle(UI.muted)
  }

  private func openCSV() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    let onClose: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK, let url = panel.url else { return }
      isLoading = true
      error = nil
      DispatchQueue.global(qos: .userInitiated).async {
        let result = Result { try ChartCSV.load(url) }
        DispatchQueue.main.async {
          isLoading = false
          switch result {
          case .success(let table):
            csv = table
            embedded = nil
            header = true
            x = 0
            y = min(1, table.columnCount - 1)
            title = url.deletingPathExtension().lastPathComponent
            rebuild()
          case .failure(let failure): error = failure.localizedDescription
          }
        }
      }
    }
    if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: onClose) }
    else { panel.begin(completionHandler: onClose) }
  }

  private func useSelected() {
    embedded = selected?.chart
    if let embedded {
      kind = embedded.kind
      title = embedded.title
    } else { title = "" }
    rebuild()
  }

  private func rebuild() {
    let id = UUID()
    request = id
    draft = nil
    let (kind, title, csv, embedded, header, x, y, accent, style) = (
      kind, title.trimmingCharacters(in: .whitespacesAndNewlines), csv, embedded, header, x, y, accent, style)
    DispatchQueue.global(qos: .userInitiated).async {
      var spec = ChartSpec(kind: kind, title: title, points: [])
      var skipped = 0
      if let csv {
        (spec.points, skipped) = csv.points(for: kind, header: header, x: x, y: y)
        if header {
          let names = csv.columns(header: true)
          spec.xTitle = names[x]
          spec.yTitle = names[y]
        }
      } else if let embedded {
        spec = embedded
        spec.kind = kind
        spec.title = title
        spec.points = embedded.points.filter {
          (kind != .pie || $0.y > 0) && (kind != .scatter || $0.x != nil)
        }
        skipped = embedded.points.count - spec.points.count
        spec = embedded.updatingData(with: spec)
      } else {
        spec.points = [18.0, 31, 24, 46, 37].enumerated().map {
          ChartPoint(label: String(UnicodeScalar(65 + $0.offset)!), x: kind == .scatter ? Double($0.offset + 1) : nil,
                     y: $0.element)
        }
      }
      let next = spec.valid ? spec : nil
      let layout = next.map { ChartLayout($0, color: accent, aspect: 1.7, appearance: style) }
      DispatchQueue.main.async {
        guard request == id else { return }
        draft = next
        preview = layout
        previewProgress = 1
        self.skipped = skipped
      }
    }
  }

  private func insert(replace clip: Clip?) {
    guard let draft else { return }
    if let clip, let chart = clip.chart {
      editor.edit(clip.id) { $0.chart = chart.updatingData(with: draft) }
      csv = nil
      useSelected()
    } else { editor.addChart(draft, appearance: style, color: accent) }
  }

  private func hasChanges(from chart: ChartSpec, to draft: ChartSpec) -> Bool {
    var revised = draft
    revised.entryFrames = chart.entryFrames
    revised.marker = chart.marker
    return revised != chart
  }
}

private struct ChartThumbnail: View, Animatable {
  let layout: ChartLayout
  var progress: Double
  var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }

  var body: some View {
    SwiftUI.Canvas { context, size in
      context.withCGContext { g in
        g.translateBy(x: 0, y: size.height)
        g.scaleBy(x: 1, y: -1)
        layout.draw(in: CGRect(origin: .zero, size: size), progress: progress, context: g)
      }
    }
  }
}
