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
    let center = CGPoint(x: edit.x * canvas.width, y: edit.y * canvas.height)
    let motion = edit.motionOffset(at: frame, size: canvas)
    let pivot = CGPoint(x: center.x + motion.x, y: center.y + motion.y)
    let degrees = edit.angle

    ZStack(alignment: .topLeading) {
      if cropping {
        Path { path in
          let vertices = corners(geometry.full)
          path.addLines([0, 1, 3, 2].map { placed(vertices[$0], pivot: pivot, angle: degrees) })
          path.closeSubpath()
        }.stroke(.white.opacity(0.38), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
          .allowsHitTesting(false)
      }
      RoundedRectangle(cornerRadius: 1)
        .strokeBorder(cropping ? .white : UI.accent, lineWidth: 1.3)
        .background(.white.opacity(0.001)).contentShape(Rectangle())
        .frame(width: box.width, height: box.height)
        .rotationEffect(.degrees(degrees))
        .position(placed(CGPoint(x: box.midX, y: box.midY), pivot: pivot, angle: degrees))
        .allowsHitTesting(!cropping)
        .gesture(
          DragGesture(minimumDistance: 2, coordinateSpace: coordinate)
            .onChanged { value in
              var updated = clip
              updated.x = bound(clip.x + value.translation.width / canvas.width, -4, 5)
              updated.y = bound(clip.y + value.translation.height / canvas.height, -4, 5)
              draft = updated
            }.onEnded { _ in commit() })
      ForEach(0..<(cropping ? 8 : 4), id: \.self) { index in
        let point = index < 4 ? corners(box)[index] : edgePoints(box)[index - 4]
        Rectangle().fill(cropping ? .white : UI.accent)
          .overlay(Rectangle().strokeBorder(UI.deep, lineWidth: 1))
          .frame(width: 9, height: 9)
          .frame(width: 22, height: 22).contentShape(Rectangle())
          .position(placed(point, pivot: pivot, angle: degrees))
          .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: coordinate)
              .onChanged { value in
                if cropping {
                  resizeCrop(index: index, translation: value.translation)
                } else {
                  resizeMedia(index: index, translation: value.translation)
                }
              }.onEnded { _ in commit() }
          )
          .accessibilityLabel(cropping ? "裁剪手柄" : "素材缩放手柄")
      }
      if !cropping {
        let knob = CGPoint(x: box.midX, y: box.minY + min(23, box.height * 0.33))
        Image(systemName: "arrow.clockwise")
          .font(.system(size: 11, weight: .bold)).foregroundStyle(UI.deep)
          .frame(width: 22, height: 22).background(UI.accent, in: Circle())
          .contentShape(Circle()).position(placed(knob, pivot: pivot, angle: degrees))
          .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: coordinate)
              .onChanged { value in
                let begin = atan2(value.startLocation.y - pivot.y, value.startLocation.x - pivot.x)
                let end = atan2(value.location.y - pivot.y, value.location.x - pivot.x)
                var updated = clip
                updated.angle = (clip.angle + Double(end - begin) * 180 / Double.pi)
                  .truncatingRemainder(
                    dividingBy: 360)
                draft = updated
              }.onEnded { _ in commit() }
          ).help("拖动旋转素材").accessibilityLabel("旋转手柄")
      }
    }.frame(width: canvas.width, height: canvas.height)
      .onChange(of: cropping) { _ in draft = nil }
  }

  private func corners(_ r: CGRect) -> [CGPoint] {
    [
      CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
      CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
    ]
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
  private func placed(_ p: CGPoint, pivot: CGPoint, angle: Double) -> CGPoint {
    let local = rotate(p, degrees: angle)
    return CGPoint(x: pivot.x + local.x, y: pivot.y + local.y)
  }
  private func resizeMedia(index: Int, translation: CGSize) {
    let original = VisualGeometry(clip: clip, canvas: canvas, aspect: aspect).visible
    let corners = corners(original)
    let point = corners[index]
    let fixed = corners[3 - index]
    let move = rotate(CGPoint(x: translation.width, y: translation.height), degrees: -clip.angle)
    let x = point.x - fixed.x
    let y = point.y - fixed.y
    let projection = 1 + (move.x * x + move.y * y) / max(1, x * x + y * y)
    let scale = bound(clip.displayScale * projection, 0.05, 8)
    let ratio = scale / clip.displayScale
    let shift = rotate(
      CGPoint(x: fixed.x * (1 - ratio), y: fixed.y * (1 - ratio)),
      degrees: clip.angle)
    var updated = clip
    updated.visualScale = scale
    updated.x = bound(clip.x + shift.x / canvas.width, -4, 5)
    updated.y = bound(clip.y + shift.y / canvas.height, -4, 5)
    draft = updated
  }
  private func resizeCrop(index: Int, translation: CGSize) {
    let full = VisualGeometry(clip: clip, canvas: canvas, aspect: aspect).full
    let move = rotate(CGPoint(x: translation.width, y: translation.height), degrees: -clip.angle)
    let dx = move.x / full.width
    let dy = move.y / full.height
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
    draft = updated
  }
  private func commit() {
    if let draft {
      editor.edit(clip.id) { target in
        target.x = draft.x
        target.y = draft.y
        target.angle = draft.angle
        target.visualScale = draft.visualScale
        target.sourceCrop = draft.sourceCrop
      }
    }
    draft = nil
  }
}
