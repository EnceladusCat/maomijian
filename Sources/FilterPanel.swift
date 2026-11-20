import SwiftUI

struct FilterPanel: View {
  let editor: Editor
  @ObservedObject var updates: PanelUpdates

  var body: some View {
    let clips = editor.selectedClips.filter { $0.kind == .video }
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        Text(L("滤镜")).font(.headline)
        if clips.isEmpty {
          Text(L("在时间线上选择图片或视频。")).foregroundStyle(UI.muted).font(.caption)
        }
        ForEach(FootageFilter.allCases.filter { $0 != .none }, id: \.self) { filter in
          Button {
            editor.addFilter(filter)
          } label: {
            HStack(spacing: 7) {
              FilterSwatch(filter: filter).frame(width: 47, height: 35)
              Text(LKey(filter.rawValue)).font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
              Spacer(minLength: 0)
              Image(systemName: "plus").font(.caption).foregroundStyle(UI.accent).accessibilityHidden(true)
            }.padding(5).frame(maxWidth: .infinity, alignment: .leading)
              .background(UI.well, in: RoundedRectangle(cornerRadius: 5))
              .contentShape(Rectangle())
          }.buttonStyle(.plain).disabled(clips.isEmpty).help(L("添加滤镜"))
        }
        if let clip = clips.first, clips.count == 1, !clip.filters.isEmpty {
          Divider()
          FilterStackRows(editor: editor, clip: clip)
        }
        if clips.contains(where: { !$0.filters.isEmpty }) {
          Button(L("清空滤镜")) { editor.editSelectedFilters { $0.removeAll() } }
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
    SectionName(name: L("滤镜堆叠"))
    ForEach(Array(filters.enumerated()), id: \.offset) { index, filter in
      VStack(spacing: 4) {
        HStack(spacing: 5) {
          Text(LKey(filter.look.rawValue)).font(.caption.weight(.medium))
            .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
          Spacer(minLength: 0)
          Tool(symbol: "chevron.up", label: L("上移滤镜 \(index + 1)"), size: 20) { move(index, by: -1) }
            .disabled(index == 0)
          Tool(symbol: "chevron.down", label: L("下移滤镜 \(index + 1)"), size: 20) { move(index, by: 1) }
            .disabled(index == filters.count - 1)
          Tool(symbol: "xmark", label: L("移除滤镜 \(index + 1)"), size: 20) {
            edit(index) { $0.remove(at: index) }
          }
        }
        if filter.look == .backgroundKey {
          NumberRow(label: L("敏感度"), value: filter.sensitivity * 100, range: 0...100, unit: "%") { value in
            edit(index) { $0[index].keySensitivity = value / 100 }
          }.help(L("从素材边缘自动取色。提高敏感度会去除更多相近颜色。"))
        } else {
          NumberRow(label: L("强度"), value: filter.amount * 100, range: 0...100, unit: "%") { value in
            edit(index) { $0[index].amount = value / 100 }
          }
        }
        DisclosureGroup(L("缓入缓出")) {
          VStack(spacing: 6) {
            duration(L("缓入时长"), frames: filter.entryFrames) { value in
              edit(index) { $0[index].fadeInFrames = value }
            }
            duration(L("缓出时长"), frames: filter.exitFrames) { value in
              edit(index) { $0[index].fadeOutFrames = value }
            }
          }.padding(.top, 6)
        }.font(.caption)
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
  private func duration(_ label: String, frames: Int, apply: @escaping (Int) -> Void) -> some View {
    NumberRow(label: label, value: Double(frames) / Double(fps),
              range: 0...Double(max(clip.length, frames)) / Double(fps), unit: L("秒"), precision: 2) {
      apply(Int(($0 * Double(fps)).rounded()))
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
      case .edgeBlur:
        let center = CGPoint(x: rect.midX, y: rect.midY)
        context.drawLayer { layer in
          layer.addFilter(.blur(radius: 2.5))
          for x in [rect.minX + 6, rect.maxX - 6] {
            layer.fill(Path(ellipseIn: CGRect(x: x - 7, y: center.y - 10, width: 14, height: 20)),
                       with: .color(UI.accent.opacity(0.82)))
          }
        }
        let focus = CGRect(x: center.x - 7, y: center.y - 8, width: 14, height: 16)
        context.stroke(Path(roundedRect: focus, cornerRadius: 3), with: .color(UI.accent), lineWidth: 2)
      case .backgroundKey:
        for row in 0..<5 {
          for column in 0..<7 where (row + column).isMultiple(of: 2) {
            context.fill(Path(CGRect(x: column * 7, y: row * 7, width: 7, height: 7)),
                         with: .color(UI.muted.opacity(0.24)))
          }
        }
        let center = rect.midX
        context.fill(Path(ellipseIn: CGRect(x: center - 5, y: 7, width: 10, height: 10)), with: .color(UI.mint))
        context.fill(Path(roundedRect: CGRect(x: center - 10, y: 19, width: 20, height: 10), cornerRadius: 5),
                     with: .color(UI.mint))
      case .none: break
      }
    }.clipShape(RoundedRectangle(cornerRadius: 3)).accessibilityHidden(true)
  }
}
