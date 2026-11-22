import SwiftUI

struct MediaHandles: View {
  let editor: Editor
  let clip: Clip
  let canvas: CGSize
  let aspect: Double
  let frame: Int
  let cropping: Bool

  @State private var draft: Clip?
  private let coordinate = CoordinateSpace.named("canvas")

  var body: some View {
    let edit = draft ?? clip
    let geometry = VisualGeometry(clip: edit, canvas: canvas, aspect: aspect)
    let box = geometry.visible
    let placement = edit.placement(at: frame, canvas: canvas, geometry: geometry)
    let pivot = placement.center
    let scale = placement.scale
    let degrees = edit.angle

    ZStack(alignment: .topLeading) {
      if cropping {
        Path { path in
          let vertices = VisualGeometry.corners(geometry.full)
          path.addLines([0, 1, 3, 2].map { placed(vertices[$0], pivot: pivot, angle: degrees, scale: scale) })
          path.closeSubpath()
        }.stroke(.white.opacity(0.38), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
          .allowsHitTesting(false)
      }
      InsetSelectionOutline(shape: edit.pictureInset?.shape)
        .stroke(cropping ? .white : UI.accent, lineWidth: 1.3)
        .background(.white.opacity(0.001)).contentShape(Rectangle())
        .frame(width: box.width * scale, height: box.height * scale)
        .rotationEffect(.degrees(degrees))
        .position(placed(CGPoint(x: box.midX, y: box.midY), pivot: pivot, angle: degrees, scale: scale))
        .allowsHitTesting(!cropping)
        .gesture(
          DragGesture(minimumDistance: 2, coordinateSpace: coordinate)
            .onChanged { value in
              var updated = clip
              let original = clip.placement(
                at: frame, canvas: canvas, geometry: VisualGeometry(clip: clip, canvas: canvas, aspect: aspect))
              let ratio = original.anchorsToCanvas ? original.scale : 1
              updated.x = bound(clip.x + value.translation.width / (canvas.width * ratio), -4, 5)
              updated.y = bound(clip.y + value.translation.height / (canvas.height * ratio), -4, 5)
              update(updated)
            }.onEnded { _ in commit() })
      ForEach(0..<(cropping ? 8 : 4), id: \.self) { index in
        let point = index < 4 ? VisualGeometry.corners(box)[index] : edgePoints(box)[index - 4]
        Rectangle().fill(cropping ? .white : UI.accent)
          .overlay(Rectangle().strokeBorder(UI.deep, lineWidth: 1))
          .frame(width: 9, height: 9)
          .frame(width: 22, height: 22).contentShape(Rectangle())
          .position(placed(point, pivot: pivot, angle: degrees, scale: scale))
          .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: coordinate)
              .onChanged { value in
                update(resized(index: index, translation: value.translation))
              }.onEnded { value in
                editor.commitCanvas(resized(index: index, translation: value.translation))
                draft = nil
              }
          )
          .accessibilityLabel(cropping ? L("裁剪手柄") : L("素材缩放手柄"))
      }
      if !cropping {
        let knob = CGPoint(x: box.midX, y: box.minY + min(23, box.height * 0.33))
        Image(systemName: "arrow.clockwise")
          .font(.system(size: 11, weight: .bold)).foregroundStyle(UI.deep)
          .frame(width: 22, height: 22).background(UI.accent, in: Circle())
          .contentShape(Circle()).position(placed(knob, pivot: pivot, angle: degrees, scale: scale))
          .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: coordinate)
              .onChanged { value in
                let begin = atan2(value.startLocation.y - pivot.y, value.startLocation.x - pivot.x)
                let end = atan2(value.location.y - pivot.y, value.location.x - pivot.x)
                var updated = clip
                updated.angle = (clip.angle + Double(end - begin) * 180 / Double.pi)
                  .truncatingRemainder(
                    dividingBy: 360)
                update(updated)
              }.onEnded { _ in commit() }
          ).help(L("拖动旋转素材")).accessibilityLabel(L("旋转手柄"))
      }
    }.frame(width: canvas.width, height: canvas.height)
      .onChange(of: cropping) { _ in clearDraft() }
      .onDisappear(perform: clearDraft)
  }

  private func edgePoints(_ r: CGRect) -> [CGPoint] {
    [
      CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY),
      CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.maxY),
    ]
  }
  private func rotate(_ p: CGPoint, degrees: Double) -> CGPoint {
    p.applying(CGAffineTransform(rotationAngle: degrees * .pi / 180))
  }
  private func placed(_ p: CGPoint, pivot: CGPoint, angle: Double, scale: CGFloat) -> CGPoint {
    let local = rotate(p, degrees: angle)
    return CGPoint(x: pivot.x + local.x * scale, y: pivot.y + local.y * scale)
  }
  private func resized(index: Int, translation: CGSize) -> Clip {
    if cropping { return resizedCrop(index: index, translation: translation) }
    return clip.resizedFromCorner(index, by: translation, canvas: canvas, aspect: aspect, frame: frame)
  }
  private func resizedCrop(index: Int, translation: CGSize) -> Clip {
    let geometry = VisualGeometry(clip: clip, canvas: canvas, aspect: aspect)
    let scaleAtFrame = clip.placement(at: frame, canvas: canvas, geometry: geometry).scale
    let move = rotate(CGPoint(x: translation.width, y: translation.height), degrees: -clip.angle)
    let dx = move.x / (geometry.full.width * scaleAtFrame)
    let dy = move.y / (geometry.full.height * scaleAtFrame)
    var crop = clip.sourceCrop ?? SourceCrop()
    let edges = [[0, 2], [1, 2], [0, 3], [1, 3], [0], [1], [2], [3]][index]
    for edge in edges {
      switch edge {
      case 0: crop.left = bound(crop.left + dx, 0, 0.98 - crop.right)
      case 1: crop.right = bound(crop.right - dx, 0, 0.98 - crop.left)
      case 2: crop.top = bound(crop.top + dy, 0, 0.98 - crop.bottom)
      default: crop.bottom = bound(crop.bottom - dy, 0, 0.98 - crop.top)
      }
    }
    var updated = clip
    updated.sourceCrop = crop
    return updated
  }
  private func update(_ clip: Clip) {
    draft = clip
    editor.previewCanvas(clip)
  }
  private func clearDraft() {
    draft = nil
    if editor.liveCanvas.activeID == clip.id { editor.liveCanvas.clear() }
  }
  private func commit() {
    if let draft { editor.commitCanvas(draft) }
    draft = nil
  }
}

private struct InsetSelectionOutline: Shape {
  let shape: InsetShape?
  func path(in rect: CGRect) -> Path {
    Path((shape ?? .rectangle).path(rect.insetBy(dx: 0.65, dy: 0.65)))
  }
}
