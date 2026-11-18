import SwiftUI

private struct Lane: Identifiable {
  let title: String, k: Kind, index: Int
  var clips: [Clip]
  var id: String { k.rawValue + String(index) }
}
private func tracks(_ p: Project, joins: [Project.Join]) -> [Lane] {
  var all = [Lane]()
  for (k, title) in [
    (Kind.caption, "字幕"), (.text, "标注"), (.zoom, "效果"), (.video, "视频"), (.audio, "音频"),
  ] {
    if k == .video {
      all += p.videoLanes(joins).enumerated().map {
        Lane(title: title, k: k, index: $0.offset, clips: $0.element)
      }
      continue
    }
    var rows = [Lane(title: title, k: k, index: 0, clips: [])]
    let items = p.clips.filter { k == .text ? $0.kind.isArt && $0.kind != .caption : $0.kind == k }
      .sorted { $0.start < $1.start }
    for c in items {
      if let i = rows.firstIndex(where: { ($0.clips.last?.end ?? 0) <= c.start }) {
        rows[i].clips.append(c)
      } else {
        rows.append(Lane(title: title, k: k, index: rows.count, clips: [c]))
      }
    }
    all += rows
  }
  return all
}
private struct Needle: View {
  @ObservedObject var t: Transport
  let first: Double, per: Double
  var body: some View {
    GeometryReader { g in
      let x = (Double(t.frame) - first) * per
      if x >= 0 && x <= g.size.width {
        Path { p in
          p.move(to: CGPoint(x: x, y: 0))
          p.addLine(to: CGPoint(x: x, y: g.size.height))
        }.stroke(UI.accent, lineWidth: 1.4)
      }
    }.allowsHitTesting(false)
  }
}
struct Timeline: View {
  @ObservedObject var e: Editor
  @State private var groupOffset: CGFloat = 0
  @State private var zoom = 1.0
  @State private var first = 0.0
  @State private var laneFrames = [String: CGRect]()
  private let marqueeSpace = "timelineMarquee"
  let head = 78.0
  func label(_ text: String, _ k: Kind) -> some View {
    HStack(spacing: 6) {
      Image(systemName: k.icon).foregroundStyle(UI.color(k)).frame(width: 14)
      Text(text).font(.system(size: 11))
      Spacer()
    }.padding(.leading, 12).frame(width: head)
  }
  var body: some View {
    GeometryReader { geo in
      let width = max(50, geo.size.width - head - 12)
      let total = max(300, Double(e.p.duration + 30))
      let per = min(32, max(0.0001, width / total * zoom))
      let seen = width / per
      let limit = max(0, total - seen)
      let left = min(first, limit)
      let joins = e.p.joins
      let lanes = tracks(e.p, joins: joins)
      VStack(spacing: 0) {
        HStack(spacing: 9) {
          Text("时间线").font(.headline)
          Divider().frame(height: 15)
          Tool(symbol: "scissors", label: "在播放头分割（⌘B）", act: e.split).disabled(e.clip == nil)
          Tool(symbol: "square.split.2x2", label: "批量切割（⇧⌘B）", act: e.batchCut)
            .disabled(!e.canBatchCut)
          Tool(symbol: "trash", label: "删除所选片段", act: e.remove).disabled(e.clip == nil)
          Tool(
            symbol: "arrow.right.and.line.vertical.and.arrow.left", label: "删除所选时段并合拢所有轨道（⇧Delete）",
            act: e.ripple
          ).disabled(e.clip == nil)
          Spacer()
          Tool(symbol: "minus.magnifyingglass", label: "缩小时间线") {
            zoom = max(1, zoom / 2)
            first = min(first, max(0, total - seen * 2))
          }
          Tool(symbol: "plus.magnifyingglass", label: "放大时间线") {
            zoom = min(zoom * 2, max(1, 32 * total / width))
            first = max(0, Double(e.transport.frame) - seen / 8)
          }
          Tool(symbol: "arrow.left.and.right", label: "适应整个工程") {
            zoom = 1
            first = 0
          }
        }.padding(.horizontal, 13).frame(height: 34)
        HStack(spacing: 0) {
          Text("分:秒:帧").font(.caption2).foregroundStyle(UI.muted).frame(width: head)
          ZStack(alignment: .topLeading) {
            SwiftUI.Canvas { ctx, sz in
              let steps = [
                1, 2, 5, 10, 15, 30, 60, 150, 300, 450, 900, 1800, 3600, 9000, 18000, 36000, 108000,
                216000, 432000, 864000,
              ]
              let step = steps.first { Double($0) * per >= 68 } ?? 864000
              let low = Int(left) / step * step
              for f in stride(from: low, through: Int(left + seen) + 1, by: step) {
                let x = (Double(f) - left) * per
                ctx.draw(
                  Text(tc(f)).font(.system(size: 9, design: .monospaced)).foregroundColor(UI.muted),
                  at: CGPoint(x: x + 3, y: 3), anchor: .topLeading)
                var path = Path()
                path.move(to: CGPoint(x: x, y: 14))
                path.addLine(to: CGPoint(x: x, y: 21))
                ctx.stroke(path, with: .color(UI.muted.opacity(0.55)))
              }
            }
            Needle(t: e.transport, first: left, per: per)
          }.contentShape(Rectangle()).gesture(
            DragGesture(minimumDistance: 0).onChanged {
              e.scrub(Int((left + $0.location.x / per).rounded()))
            }.onEnded {
              e.seek(Int((left + $0.location.x / per).rounded()))
            })
        }.frame(height: 22).padding(.trailing, 12).background(UI.deep)
        GeometryReader { viewport in
          ScrollView(.vertical) {
            VStack(spacing: 1) {
              ForEach(lanes) { lane in
                let ids = Set(lane.clips.map(\.id))
                let laneJoins = lane.k == .video ? joins.filter { ids.contains($0.after.id) } : []
                HStack(spacing: 0) {
                  label(lane.title + (lane.index == 0 ? "" : " \(lane.index+1)"), lane.k)
                    .background(MarqueeBlank(selection: e.timelineMarquee) { e.selected = nil })
                  ZStack(alignment: .topLeading) {
                    Color.white.opacity(0.035)
                    ClipLane(
                      editor: e,
                      layout: .init(
                        pieces: lane.clips.map { .init(clip: $0, name: e.p.name($0)) },
                        selection: Set(e.selectedIDs), first: left, per: per,
                        groupOffset: groupOffset
                      ),
                      groupOffset: $groupOffset)
                    ForEach(
                      laneJoins.filter { j in
                        Double(j.frame) >= left && Double(j.frame) <= left + seen
                          && (j.active || e.selected == j.id
                            || Double(min(j.before.length, j.after.length)) * per >= 15)
                      }
                    ) { j in
                      GateMarker(
                        titles: e.p.name(j.before) + " → " + e.p.name(j.after), e: e, join: j,
                        first: left, per: per, width: width, shelf: e.shelf
                      ).equatable()
                    }
                    if lane.k == .video {
                      ForEach(
                        lane.clips.filter {
                          ($0.id == e.selected || $0.startEffect != nil || $0.endEffect != nil)
                            && Double($0.end) >= left && Double($0.start) <= left + seen
                        }
                      ) { clip in
                        ForEach(ClipEnd.allCases, id: \.self) { side in
                          EdgeMarker(
                            editor: e, shelf: e.shelf, clip: clip, side: side,
                            first: left, per: per, width: width)
                        }
                      }
                    }
                    Needle(t: e.transport, first: left, per: per)
                  }.clipped()
                    .background(MarqueeTarget(id: lane.id, space: marqueeSpace))
                    .background {
                      if lane.k == .video {
                        DropBandReader(
                          first: left, per: per, joins: Set(laneJoins.map(\.id)), clips: ids)
                      }
                    }
                }.frame(height: 30).padding(.trailing, 12)
              }
              MarqueeBlank(selection: e.timelineMarquee) { e.selected = nil }
                .frame(height: max(0, viewport.size.height - CGFloat(lanes.count) * 31))
                .padding(.leading, head).padding(.trailing, 12)
            }
          }.overlay {
            MarqueeOverlay(selection: e.timelineMarquee, leftInset: head, rightInset: 12) {
              box, flags in
              let hits = lanes.flatMap { lane -> [UUID] in
                guard let frame = laneFrames[lane.id], frame.intersects(box) else { return [] }
                return lane.clips.compactMap { clip in
                  let rect = ClipLane.clipBox(clip, first: left, per: per)
                    .offsetBy(dx: frame.minX, dy: frame.minY).intersection(frame)
                  return rect.intersection(box).isEmpty ? nil : clip.id
                }
              }
              e.pickMarquee(hits, modifiers: flags, inLibrary: false)
            }.allowsHitTesting(false)
          }.coordinateSpace(name: marqueeSpace)
            .onPreferenceChange(MarqueeBounds<String>.self) { laneFrames = $0 }
        }
        if limit > 0.5 {
          HStack {
            Text("平移").font(.caption2).foregroundStyle(UI.muted).frame(width: head)
            Slider(value: Binding(get: { left }, set: { first = $0 }), in: 0...limit).controlSize(
              .mini)
          }.padding(.trailing, 12).frame(height: 18)
        }
      }.background(UI.panel).onReceive(e.transport.$frame) { f in
        if e.transport.playing && (Double(f) < left || Double(f) > left + seen) {
          first = bound(Double(f) - seen * 0.1, 0, limit)
        }
      }
    }
  }
}
