import SwiftUI

private func normalized(_ p: CGPoint, _ size: CGSize) -> CGPoint {
  CGPoint(x: bound(p.x / size.width, 0, 1), y: bound(p.y / size.height, 0, 1))
}
private func box(_ a: CGPoint, _ b: CGPoint) -> CGRect {
  CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
}
struct RegionControls: View {
  @ObservedObject var e: Editor
  let c: Clip?, size: CGSize
  @State private var draft: CGRect?
  private var shape: RegionShape { e.regionTool == nil ? c?.shape ?? .rectangle : e.drawShape }
  private var displayed: CGRect? { (draft ?? c?.region).map { shape.fit($0, in: size) } }
  var body: some View {
    ZStack(alignment: .topLeading) {
      if let tool = e.regionTool {
        RegionDrawingSurface(
          shape: shape, update: { draft = $0 },
          finish: { rect in
            if rect.width * size.width >= 5, rect.height * size.height >= 5, rect.width >= 0.01,
              rect.height >= 0.01
            {
              e.finishRegion(rect)
            }
            draft = nil
          }
        ).frame(width: size.width, height: size.height)
        HStack(spacing: 8) {
          Text(tool == .zoom ? L("拖出需要放大的区域") : L("拖出需要保留亮度的区域"))
            .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
          Button(L("取消")) {
            e.regionTool = nil
            draft = nil
          }.buttonStyle(.borderless)
        }.font(.callout).padding(.horizontal, 10).padding(.vertical, 5).background(
          UI.panel, in: Capsule()
        ).padding(.horizontal, 8).frame(maxWidth: .infinity).padding(.top, 7)
      }
      if let rect = displayed, e.regionTool == nil || draft != nil {
        let r = rect.applying(CGAffineTransform(scaleX: size.width, y: size.height))
        let stroke = RegionOutline(shape: shape).stroke(
          .white, style: StrokeStyle(lineWidth: 1.2, dash: [5, 3])
        )
        .shadow(color: .black, radius: 1)
        if e.regionTool != nil {
          stroke.frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
            .allowsHitTesting(false)
        } else if let c {
          stroke.background(Color.white.opacity(0.001)).frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
            .gesture(
              DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas")).onChanged { v in
                let old = c.shape.fit(c.region, in: size)
                draft = CGRect(
                  x: bound(old.minX + v.translation.width / size.width, 0, 1 - old.width),
                  y: bound(old.minY + v.translation.height / size.height, 0, 1 - old.height),
                  width: old.width, height: old.height)
              }.onEnded { _ in commit(c) })
          ForEach(0..<4, id: \.self) { corner in
            let right = corner % 2 == 1
            let bottom = corner >= 2
            Circle().fill(.white).overlay(Circle().stroke(UI.deep, lineWidth: 1.2)).frame(
              width: 9, height: 9
            )
            .frame(width: 18, height: 18).contentShape(Rectangle()).position(
              x: right ? r.maxX : r.minX, y: bottom ? r.maxY : r.minY
            )
            .gesture(
              DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas")).onChanged { v in
                let p = normalized(v.location, size)
                let old = c.shape.fit(c.region, in: size)
                let fixed = CGPoint(x: right ? old.minX : old.maxX, y: bottom ? old.minY : old.maxY)
                let x = right ? max(fixed.x + 0.02, p.x) : min(fixed.x - 0.02, p.x)
                let y = bottom ? max(fixed.y + 0.02, p.y) : min(fixed.y - 0.02, p.y)
                draft = box(fixed, CGPoint(x: bound(x, 0, 1), y: bound(y, 0, 1)))
              }.onEnded { _ in commit(c) })
          }
        }
      }
    }.frame(width: size.width, height: size.height)
      .onChange(of: e.regionTool) { _ in draft = nil }
  }
  private func commit(_ c: Clip) {
    if let draft { e.edit(c.id) { $0.setRegion(shape.fit(draft, in: size)) } }
    draft = nil
  }
}

private struct RegionOutline: Shape {
  let shape: RegionShape
  func path(in rect: CGRect) -> Path { Path(shape.path(rect)) }
}

private struct RegionDrawingSurface: NSViewRepresentable {
  let shape: RegionShape, update: (CGRect) -> Void, finish: (CGRect) -> Void
  func makeNSView(context: Context) -> Surface {
    let v = Surface()
    v.tool = self
    return v
  }
  func updateNSView(_ v: Surface, context: Context) { v.tool = self }
  final class Surface: NSView {
    var tool: RegionDrawingSurface?, anchor = CGPoint.zero
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
      super.resetCursorRects()
      addCursorRect(bounds, cursor: .crosshair)
    }
    override func mouseDown(with event: NSEvent) {
      anchor = point(event)
      tool?.update(.zero)
    }
    override func mouseDragged(with event: NSEvent) { tool?.update(area(event)) }
    override func mouseUp(with event: NSEvent) { tool?.finish(area(event)) }
    func point(_ e: NSEvent) -> CGPoint {
      normalized(convert(e.locationInWindow, from: nil), bounds.size)
    }
    func area(_ e: NSEvent) -> CGRect {
      let p = point(e)
      if tool?.shape == .rectangle { return box(anchor, p) }
      let sx = p.x >= anchor.x ? 1.0 : -1.0
      let sy = p.y >= anchor.y ? 1.0 : -1.0
      let dx = abs(p.x - anchor.x) * bounds.width
      let dy = abs(p.y - anchor.y) * bounds.height
      let xmax = (sx > 0 ? 1 - anchor.x : anchor.x) * bounds.width
      let ymax = (sy > 0 ? 1 - anchor.y : anchor.y) * bounds.height
      let side = min(max(dx, dy), min(xmax, ymax))
      return box(
        anchor,
        CGPoint(x: anchor.x + sx * side / bounds.width, y: anchor.y + sy * side / bounds.height))
    }
  }
}
