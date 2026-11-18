import SwiftUI

struct FilterPanel: View {
  let editor: Editor
  @ObservedObject var updates: PanelUpdates

  var body: some View {
    let clips = editor.selectedClips.filter { $0.kind == .video }
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        Text("滤镜").font(.headline)
        if clips.isEmpty {
          Text("在时间线上选择图片或视频。").foregroundStyle(UI.muted).font(.caption)
        }
        ForEach(FootageFilter.allCases.filter { $0 != .none }, id: \.self) { filter in
          Button {
            editor.addFilter(filter)
          } label: {
            HStack(spacing: 9) {
              FilterSwatch(filter: filter).frame(width: 54, height: 35)
              Text(filter.rawValue).font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
              Spacer(minLength: 0)
              Image(systemName: "plus").font(.caption).foregroundStyle(UI.accent).accessibilityHidden(true)
            }.padding(5).frame(maxWidth: .infinity, alignment: .leading)
              .background(UI.well, in: RoundedRectangle(cornerRadius: 5))
              .contentShape(Rectangle())
          }.buttonStyle(.plain).disabled(clips.isEmpty).help("添加滤镜")
        }
        if let clip = clips.first, clips.count == 1, !clip.filters.isEmpty {
          Divider()
          FilterStackRows(editor: editor, clip: clip)
        }
        if clips.contains(where: { !$0.filters.isEmpty }) {
          Button("清空滤镜") { editor.editSelectedFilters { $0.removeAll() } }
        }
      }.padding(12)
    }
  }
}

struct FilterStackRows: View {
  let editor: Editor
  let clip: Clip

  var body: some View {
    let filters = clip.filters
    SectionName(name: "滤镜堆叠")
    ForEach(Array(filters.enumerated()), id: \.offset) { index, filter in
      VStack(spacing: 4) {
        HStack(spacing: 5) {
          Text(filter.look.rawValue).font(.caption.weight(.medium)).lineLimit(1)
          Spacer(minLength: 0)
          Tool(symbol: "chevron.up", label: "上移滤镜 \(index + 1)") { move(index, by: -1) }
            .disabled(index == 0)
          Tool(symbol: "chevron.down", label: "下移滤镜 \(index + 1)") { move(index, by: 1) }
            .disabled(index == filters.count - 1)
          Tool(symbol: "xmark", label: "移除滤镜 \(index + 1)") {
            edit(index) { $0.remove(at: index) }
          }
        }
        NumberRow(label: "强度", value: filter.amount * 100, range: 0...100, unit: "%") { value in
          edit(index) { $0[index].amount = value / 100 }
        }
      }.padding(7).background(UI.well, in: RoundedRectangle(cornerRadius: 5))
    }
  }

  private func edit(_ index: Int, _ body: (inout [ClipFilter]) -> Void) {
    editor.edit(clip.id) {
      var filters = $0.filters
      guard filters.indices.contains(index) else { return }
      body(&filters)
      if filters != $0.filters { $0.filters = filters }
    }
  }
  private func move(_ index: Int, by delta: Int) {
    edit(index) { filters in
      if filters.indices.contains(index + delta) { filters.swapAt(index, index + delta) }
    }
  }
}
private struct FilterSwatch: View {
  let filter: FootageFilter
  var body: some View {
    SwiftUI.Canvas { context, size in
      let rect = CGRect(origin: .zero, size: size)
      context.fill(Path(rect), with: .color(UI.deep))
      switch filter {
      case .camera:
        var mark = Path()
        for (x, dx) in [(5.0, 1.0), (size.width - 5, -1)] {
          for (y, dy) in [(5.0, 1.0), (size.height - 5, -1)] {
            mark.move(to: CGPoint(x: x + dx * 6, y: y))
            mark.addLine(to: CGPoint(x: x, y: y))
            mark.addLine(to: CGPoint(x: x, y: y + dy * 5))
          }
        }
        context.stroke(mark, with: .color(.white), lineWidth: 1)
        context.fill(
          Path(ellipseIn: CGRect(x: 11, y: 10, width: 5, height: 5)),
          with: .color(Color(red: 0.95, green: 0.41, blue: 0.47)))
        context.draw(
          Text("REC").font(.system(size: 7, weight: .semibold, design: .monospaced)),
          at: CGPoint(x: 19, y: 12), anchor: .leading)
      case .vhs:
        let bars: [Color] = [.indigo, .purple, .pink, .orange, .green, .cyan]
        for (index, color) in bars.enumerated() {
          let width = size.width / CGFloat(bars.count)
          context.fill(
            Path(
              CGRect(
                x: width * CGFloat(index), y: 0, width: width + 1,
                height: size.height)), with: .color(color.opacity(0.65)))
        }
        for y in stride(from: 1.0, to: size.height, by: 3) {
          context.fill(
            Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
            with: .color(.black.opacity(0.42)))
        }
      case .neon:
        for (delta, color) in [(2.0, Color.cyan), (-2, Color.pink)] {
          var glyph = Path()
          glyph.move(to: CGPoint(x: 11 + delta, y: 25))
          glyph.addLine(to: CGPoint(x: 28 + delta, y: 8))
          glyph.addLine(to: CGPoint(x: 42 + delta, y: 25))
          context.stroke(glyph, with: .color(color.opacity(0.35)), lineWidth: 6)
          context.stroke(glyph, with: .color(color), lineWidth: 1.5)
        }
      case .prism:
        for (offset, color) in [(-2.0, Color.cyan), (2, Color.pink)] {
          let r = CGRect(x: 14 + offset, y: 7 + offset, width: 26, height: 21)
          context.stroke(Path(ellipseIn: r), with: .color(color), lineWidth: 2)
        }
      case .none: break
      }
    }.clipShape(RoundedRectangle(cornerRadius: 3)).accessibilityHidden(true)
  }
}
