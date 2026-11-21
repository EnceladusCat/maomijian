import SwiftUI

private func transitionRange(
  _ target: TransitionTarget, anchor: Int, frames: Int
) -> Range<Int> {
  switch target {
  case .join:
    let start = anchor - frames / 2
    return start..<start + frames
  case .edge(let edge):
    return edge.end == .head ? anchor..<anchor + frames : anchor - frames..<anchor
  }
}

struct TransitionMarker: View {
  let editor: Editor
  let target: TransitionTarget
  let effect: ClipEdgeEffect?
  let range: Range<Int>?
  let anchor: Int
  let title: String
  let first: Double, per: Double, width: Double
  @State private var resizing: Int?
  @State private var resizeLimit: Int?
  @State private var hovering = false

  private var selected: Bool { editor.selectedTransition == target }
  private func x(_ frame: Int) -> Double { (Double(frame) - first) * per }
  private var handles: [ClipEnd] {
    switch target {
    case .join: return [.head, .tail]
    case .edge(let edge): return [edge.end == .head ? .tail : .head]
    }
  }

  var body: some View {
    let active = effect != nil
    let span = resizing.map { transitionRange(target, anchor: anchor, frames: $0) } ?? range
    let center = span.map { (x($0.lowerBound) + x($0.upperBound)) / 2 } ?? x(anchor)
    let half = max(active ? 9 : 6, Double(span?.count ?? 0) * per / 2)
    let left = max(0, center - half)
    let right = min(width, center + half)
    let color: Color = selected || hovering ? .white : (active ? UI.accent : UI.muted)
    if right > left {
      Button {
        if active { editor.selectTransition(target) }
        else { editor.placeTransition(editor.lastTransitionStyle, on: [target]) }
      } label: {
        CanvasGate(color: color, active: active)
          .frame(width: right - left, height: active ? 15 : 9)
          .contentShape(Rectangle())
      }.buttonStyle(.plain)
        .overlay {
          if active { TransitionDragSurface(e: editor, origin: .marker(target)) }
        }
        .position(x: (left + right) / 2, y: active ? 10 : 8)
        .onHover { hovering = $0 }
        .accessibilityLabel(effect.map { L("编辑\(LKey($0.style.rawValue))，\(title)") } ?? L("添加\(title)"))
        .help(active ? L("拖动转场改变位置，拖动边缘调整时长") : L("添加转场，也可从转场面板拖放"))
        .contextMenu {
          if active {
            Button(L("预览转场")) { editor.previewTransition(target) }
            Button(L("移除转场")) { editor.editTransition(target, frames: 0) }
          }
        }
      if let effect, let span, let initial = range {
        ForEach(handles, id: \.self) { side in
          let realX = x(side == .head ? initial.lowerBound : initial.upperBound)
          let visibleX = x(side == .head ? span.lowerBound : span.upperBound)
          if realX >= 0, realX <= width {
            let hitWidth = min(18, max(8, half * 0.8))
            durationHandle(side, frames: effect.frames, color: color, hitWidth: hitWidth)
              .position(x: bound(visibleX, 4, width - 4), y: 15)
          }
        }
      }
      if let resizing {
        Text(String(format: L("%.2f 秒"), Double(resizing) / Double(fps)))
          .font(.caption2.monospacedDigit())
          .padding(.horizontal, 4).padding(.vertical, 2)
          .background(UI.deep, in: RoundedRectangle(cornerRadius: 3))
          .fixedSize().position(x: (left + right) / 2, y: 28)
          .allowsHitTesting(false)
      }
    }
  }

  private func durationHandle(_ side: ClipEnd, frames: Int, color: Color, hitWidth: Double) -> some View {
    let multiplier: Double
    switch target {
    case .join: multiplier = 2
    case .edge: multiplier = 1
    }
    let sign = side == .head ? -1.0 : 1.0
    func duration(_ value: CGFloat) -> Int {
      let shift = Int((Double(value) / per * multiplier * sign).rounded())
      return bound(frames + shift, 2, max(2, resizeLimit ?? editor.p.transitionFrameLimit(target)))
    }
    return RoundedRectangle(cornerRadius: 1)
      .fill(color.opacity(selected || hovering || resizing != nil ? 1 : 0.65))
      .frame(width: 3, height: 7)
      .frame(width: hitWidth, height: 22)
      .contentShape(Rectangle())
      .onHover { inside in
        if inside { NSCursor.resizeLeftRight.set() }
        else if resizing == nil { NSCursor.arrow.set() }
      }
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
          .onChanged { value in
            if resizeLimit == nil { resizeLimit = editor.p.transitionFrameLimit(target) }
            let next = duration(value.translation.width)
            if resizing != next { resizing = next }
          }
          .onEnded { value in
            let final = duration(value.translation.width)
            resizeLimit = nil
            resizing = nil
            editor.editTransition(target, frames: final)
            NSCursor.arrow.set()
          })
      .help(L("拖动调整转场时长"))
      .accessibilityLabel(L("调整转场时长"))
  }
}

struct TransitionDropHighlight: View {
  @ObservedObject var shelf: ShelfState
  let joins: [Project.Join]
  let clips: [Clip]
  let first: Double, per: Double, width: Double

  var body: some View {
    SwiftUI.Canvas { context, size in
      for target in shelf.dropTargets {
        let span: Range<Int>
        switch target {
        case .join(let id):
          guard let join = joins.first(where: { $0.id == id }) else { continue }
          span = transitionRange(target, anchor: join.frame, frames: join.active ? join.after.blend : 15)
        case .edge(let edge):
          guard let clip = clips.first(where: { $0.id == edge.clipID }) else { continue }
          let frames = min(15, max(2, shelf.dropTargets.count == 2 ? clip.length / 2 : clip.length))
          span = transitionRange(target, anchor: edge.end == .head ? clip.start : clip.end, frames: frames)
        }
        let x = (Double(span.lowerBound) - first) * per
        let right = x + max(7, Double(span.count) * per)
        let start = max(0, x)
        let end = min(width, right)
        if end > start {
          let path = Path(roundedRect: CGRect(x: start, y: 2, width: end - start, height: size.height - 4),
                          cornerRadius: 3)
          context.fill(path, with: .color(UI.accent.opacity(0.38)))
          context.stroke(path, with: .color(UI.accent), lineWidth: 2)
        }
      }
    }.allowsHitTesting(false).accessibilityHidden(true)
  }
}

struct TransitionProperties: View {
  let editor: Editor
  let target: TransitionTarget
  let effect: ClipEdgeEffect

  private var name: String {
    switch target {
    case .join(let id):
      guard let join = editor.p.joins.first(where: { $0.id == id }) else { return L("接缝转场") }
      return editor.p.name(join.before) + " → " + editor.p.name(join.after)
    case .edge(let edge):
      guard let clip = editor.p.clips.first(where: { $0.id == edge.clipID }) else { return L("素材转场") }
      return editor.p.name(clip) + " " + LKey(edge.end.rawValue)
    }
  }

  var body: some View {
    Text(LKey(effect.style.rawValue)).font(.headline)
    Text(name).font(.caption).foregroundStyle(UI.muted).lineLimit(2)
    NumberRow(
      label: L("转场时长"), value: Double(effect.frames) / Double(fps),
      range: 2.0 / Double(fps)...Double(max(2, editor.p.transitionFrameLimit(target))) / Double(fps),
      unit: L("秒"), precision: 2
    ) { editor.editTransition(target, frames: Int(($0 * Double(fps)).rounded())) }
    Button(L("预览转场")) { editor.previewTransition(target) }
    Button(L("移除转场")) { editor.editTransition(target, frames: 0) }
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
      if active { ctx.fill(Path(box), with: .color(UI.deep.opacity(0.82))) }
      var arch = Path()
      arch.move(to: CGPoint(x: l, y: b))
      arch.addLine(to: CGPoint(x: l, y: t))
      arch.addLine(to: CGPoint(x: r, y: t))
      arch.addLine(to: CGPoint(x: r, y: b))
      ctx.stroke(
        arch, with: .color(color),
        style: StrokeStyle(lineWidth: active ? 2 : 1.4, lineCap: .round, lineJoin: .round))
    }
  }
}
