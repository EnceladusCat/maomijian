import SwiftUI

struct GateMarker: View, Equatable {
  static func == (a: Self, b: Self) -> Bool {
    a.e === b.e && a.join.before == b.join.before && a.join.after == b.join.after
      && a.first == b.first && a.per == b.per && a.width == b.width && a.titles == b.titles
  }
  let titles: String
  let e: Editor, join: Project.Join, first: Double, per: Double, width: Double
  @ObservedObject var shelf: ShelfState
  @State private var hovering = false
  var body: some View {
    let x = (Double(join.frame) - first) * per
    let overlap = Double(join.range.count) * per
    let half = join.active ? max(7, overlap / 2) : 6.0
    let left = max(0, x - half)
    let right = min(width, x + half)
    if right > left {
      let selected =
        shelf.dropJoin == join.id || shelf.targetJoinID == join.id
      let color = selected || hovering ? Color.white : (join.active ? UI.accent : UI.muted)
      let style = join.active ? join.after.transitionStyle : shelf.transitionStyle
      let title = (join.active ? "编辑" : "添加") + style.rawValue + "转场 " + tc(join.frame)
      Button {
        e.chooseJoin(join)
        if !join.active { e.transition(join.id, frames: shelf.transitionFrames, style: style) }
      } label: {
        CanvasGate(color: color, active: join.active)
          .frame(width: max(3, right - left), height: join.active ? 14 : 9)
          .padding(.bottom, 3).contentShape(Rectangle())
      }.buttonStyle(.plain)
        .position(x: (left + right) / 2, y: join.active ? 10.5 : 8)
        .onHover { hovering = $0 }
        .accessibilityLabel(title).help(
          title + " · " + titles)
    }
  }
}
private struct CanvasGate: View {
  var color: Color, active: Bool
  var body: some View {
    SwiftUI.Canvas { ctx, size in
      let l = 1.0
      let r = max(1, size.width - 1)
      let t = 1.0
      let b = size.height - 1
      let box = CGRect(x: l, y: t, width: r - l, height: b - t)
      if active { ctx.fill(Path(box), with: .color(UI.deep.opacity(0.79))) }
      var arch = Path()
      arch.move(to: CGPoint(x: l, y: b))
      arch.addLine(to: CGPoint(x: l, y: t))
      arch.addLine(to: CGPoint(x: r, y: t))
      arch.addLine(to: CGPoint(x: r, y: b))
      ctx.stroke(
        arch, with: .color(color),
        style: StrokeStyle(lineWidth: active ? 2 : 1.4, lineCap: .round, lineJoin: .round))
      if active {
        var center = Path()
        center.move(to: CGPoint(x: box.midX, y: t + 2))
        center.addLine(to: CGPoint(x: box.midX, y: b))
        ctx.stroke(
          center, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
      }
    }
  }
}

struct EdgeMarker: View {
  let editor: Editor
  @ObservedObject var shelf: ShelfState
  let clip: Clip
  let side: ClipEnd
  let first: Double, per: Double, width: Double

  @ViewBuilder var body: some View {
    let span = Double(clip.length) * per
    let start = (Double(clip.start) - first) * per
    let target = EdgeTarget(clipID: clip.id, end: side)
    let effect = clip.effect(at: side)
    let selected =
      shelf.dropEdge == target
      || (shelf.transitionSection == .edge && editor.edgeTarget == target)
    let inset = min(8.0, span * 0.24)
    let x = side == .head ? start + inset : start + span - inset
    if (span >= 24 || effect != nil) && x >= 4 && x <= width - 4 {
      marker(target, highlighted: effect != nil || selected)
        .position(x: x, y: 22)
    }
  }

  private func marker(_ target: EdgeTarget, highlighted: Bool) -> some View {
    let name = side.rawValue + "转场"
    let label = clip.effect(at: side).map { name + " " + $0.style.rawValue } ?? name
    let ink: Color = highlighted ? UI.deep : Color.white
    let well: Color = highlighted ? UI.accent : UI.deep.opacity(0.9)
    let symbol = side == .head ? "chevron.right" : "chevron.left"
    return Button(action: { editor.chooseEdge(target) }) {
      Image(systemName: symbol)
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(ink)
        .frame(width: 12, height: 12)
        .background(well, in: RoundedRectangle(cornerRadius: 2))
    }.buttonStyle(.plain).accessibilityLabel(label)
      .help(editor.p.name(clip) + " " + name)
  }
}
