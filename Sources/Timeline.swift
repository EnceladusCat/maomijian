import Combine
import QuartzCore
import SwiftUI

private struct Needle: NSViewRepresentable {
  let t: Transport
  let first: Double, per: Double

  func makeNSView(context: Context) -> Surface { Surface() }

  func updateNSView(_ view: Surface, context: Context) {
    view.configure(t, first: first, per: per)
  }

  final class Surface: NSView {
    private let marker = CALayer()
    private weak var transport: Transport?
    private var observer: AnyCancellable?
    private var frameNumber = 0
    private var first = 0.0, per = 1.0

    override init(frame: NSRect) {
      super.init(frame: frame)
      wantsLayer = true
      marker.backgroundColor = NSColor(UI.accent).cgColor
      layer?.addSublayer(marker)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ next: Transport, first: Double, per: Double) {
      self.first = first
      self.per = per
      if transport !== next {
        transport = next
        observer = next.$frame.removeDuplicates().sink { [weak self] frame in
          self?.frameNumber = frame
          self?.moveMarker()
        }
      }
      moveMarker()
    }

    override func layout() {
      super.layout()
      moveMarker()
    }

    private func moveMarker() {
      let x = (Double(frameNumber) - first) * per
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      marker.isHidden = x < 0 || x > bounds.width
      marker.frame = CGRect(x: x - 0.7, y: 0, width: 1.4, height: bounds.height)
      CATransaction.commit()
    }
  }
}
private final class AlignmentState: ObservableObject {
  @Published private(set) var frame: Int?
  func show(_ value: Int?) { if frame != value { frame = value } }
}
private struct AlignmentLine: View {
  @ObservedObject var alignment: AlignmentState
  let first: Double, per: Double, inset: Double, width: Double

  var body: some View {
    GeometryReader { geometry in
      if let frame = alignment.frame {
        let x = (Double(frame) - first) * per
        if x >= 0 && x <= width {
          Path { p in
            p.move(to: CGPoint(x: inset + x, y: 0))
            p.addLine(to: CGPoint(x: inset + x, y: geometry.size.height))
          }.stroke(UI.color(.audio), lineWidth: 2)
        }
      }
    }.allowsHitTesting(false).accessibilityHidden(true)
  }
}
struct Timeline: View {
  @ObservedObject var e: Editor
  @ObservedObject var waveforms: WaveformStore
  @State private var groupOffset: CGFloat = 0
  @StateObject private var alignment = AlignmentState()
  @State private var zoom = 1.0
  @State private var first = 0.0
  @State private var laneFrames = [String: CGRect]()
  @GestureState private var trackDrop: TrackDrop?
  private let marqueeSpace = "timelineMarquee"
  let head = AppLanguage.current == .english ? 122.0 : 78.0

  private struct TrackDrop {
    let destination: String, after: Bool
  }
  private func trackDestination(_ source: String, y: Double, order: [String]) -> TrackDrop? {
    guard let from = order.firstIndex(of: source), let to = order.indices.min(by: {
      abs((laneFrames[order[$0]]?.midY ?? .infinity) - y)
        < abs((laneFrames[order[$1]]?.midY ?? .infinity) - y)
    }), from != to, laneFrames[order[to]] != nil else { return nil }
    return TrackDrop(destination: order[to], after: to > from)
  }
  @ViewBuilder private func trackHeader(_ track: TimelineTrack, order: [String]) -> some View {
    let label = HStack(spacing: 4) {
      Image(systemName: track.kind.icon).foregroundStyle(UI.color(track.kind)).frame(width: 13)
      Text(track.name).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.88).layoutPriority(1)
      Spacer(minLength: 0)
      Image(systemName: track.pinned ? "lock" : "line.3.horizontal")
        .font(.system(size: 8)).foregroundStyle(UI.muted.opacity(0.7))
    }.padding(.horizontal, 8).frame(width: head).frame(maxHeight: .infinity).contentShape(Rectangle())
    if let index = order.firstIndex(of: track.id) {
      label.help(L("拖动轨道标题调整层级"))
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(marqueeSpace))
          .updating($trackDrop) { value, state, _ in
            state = trackDestination(track.id, y: value.location.y, order: order)
          }.onEnded { value in
            if let drop = trackDestination(track.id, y: value.location.y, order: order) {
              e.change { $0.moveTrack(track.id, to: drop.destination) }
            }
          })
        .contextMenu {
          Button(L("上移轨道")) { e.change { $0.moveTrack(track.id, to: order[index - 1]) } }
            .disabled(index == 0)
          Button(L("下移轨道")) { e.change { $0.moveTrack(track.id, to: order[index + 1]) } }
            .disabled(index + 1 == order.count)
        }
    } else {
      label.help(L("字幕固定在最上方"))
    }
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
      let lanes = e.p.timelineTracks(joins: joins)
      let order = lanes.filter { !$0.pinned }.map(\.id)
      let selected = Set(e.selectedIDs)
      let movedLeft = left - groupOffset / per
      VStack(spacing: 0) {
        HStack(spacing: 9) {
          Text(L("时间线")).font(.headline)
          Divider().frame(height: 15)
          Tool(symbol: "scissors", label: L("在播放头分割（⌘B）"), act: e.split).disabled(e.clip == nil)
          Tool(symbol: "square.split.2x2", label: L("批量切割（⇧⌘B）"), act: e.batchCut)
            .disabled(!e.canBatchCut)
          Tool(symbol: "link", label: L("编组（⌘G）"), act: e.groupSelection).disabled(!e.canGroup)
          Tool(symbol: "rectangle.on.rectangle.slash", label: L("取消编组（⇧⌘G）"), act: e.ungroupSelection)
            .disabled(!e.canUngroup)
          Tool(
            symbol: "trash", label: e.selectedTransition == nil ? L("删除所选片段") : L("移除所选转场"),
            act: e.remove
          ).disabled(e.clip == nil && e.selectedTransition == nil)
          Tool(
            symbol: "arrow.right.and.line.vertical.and.arrow.left", label: L("删除所选时段并合拢所有轨道（⇧Delete）"),
            act: e.ripple
          ).disabled(e.clip == nil)
          Spacer()
          Tool(symbol: "minus.magnifyingglass", label: L("缩小时间线")) {
            zoom = max(1, zoom / 2)
            first = min(first, max(0, total - seen * 2))
          }
          Tool(symbol: "plus.magnifyingglass", label: L("放大时间线")) {
            zoom = min(zoom * 2, max(1, 32 * total / width))
            first = max(0, Double(e.transport.frame) - seen / 8)
          }
          Tool(symbol: "arrow.left.and.right", label: L("适应整个工程")) {
            zoom = 1
            first = 0
          }
        }.padding(.horizontal, 13).frame(height: 34)
        HStack(spacing: 0) {
          Text(L("分:秒:帧")).font(.caption2).foregroundStyle(UI.muted).frame(width: head)
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
            Needle(t: e.transport, first: left, per: per).allowsHitTesting(false)
          }.contentShape(Rectangle()).gesture(
            DragGesture(minimumDistance: 0).onChanged {
              e.scrub(Int((left + $0.location.x / per).rounded()))
            }.onEnded {
              finishWorkspaceTextEditing()
              e.seek(Int((left + $0.location.x / per).rounded()))
            })
        }.frame(height: 22).padding(.trailing, 12).background(UI.deep)
        GeometryReader { viewport in
          ScrollView(.vertical) {
            VStack(spacing: 1) {
              ForEach(lanes) { lane in
                let transitionClips = lane.clips.filter { $0.kind.supportsTransitions }
                let ids = Set(transitionClips.map(\.id))
                let laneJoins = joins.filter { ids.contains($0.after.id) && ids.contains($0.before.id) }
                HStack(spacing: 0) {
                  trackHeader(lane, order: order)
                  ZStack(alignment: .topLeading) {
                    Color.white.opacity(0.035)
                    ClipLane(
                      editor: e,
                      layout: .init(
                        pieces: lane.clips.map {
                          let media = e.p.asset($0.asset)
                          let wave = $0.asset.flatMap { waveforms.values[$0] }
                          return .init(
                            clip: $0, name: e.p.name($0),
                            hasAudio: media?.audio == true || wave != nil, waveform: wave)
                        },
                        selection: selected, first: left, per: per,
                        groupOffset: groupOffset
                      ),
                      showAlignment: alignment.show, groupOffset: $groupOffset)
                    ForEach(
                      laneJoins.filter { $0.active || Double(min($0.before.length, $0.after.length)) * per >= 15 }
                    ) { join in
                      let beforeMoves = selected.contains(join.before.id)
                      let afterMoves = selected.contains(join.after.id)
                      let origin = beforeMoves && afterMoves ? movedLeft : left
                      if (groupOffset == 0 || beforeMoves == afterMoves)
                        && Double(join.range.upperBound) >= origin
                        && Double(join.range.lowerBound) <= origin + seen
                      {
                        TransitionMarker(
                          editor: e, target: .join(join.id),
                          effect: join.active ? ClipEdgeEffect(style: join.after.transitionStyle, frames: join.after.blend) : nil,
                          range: join.active ? join.range : nil, anchor: join.frame,
                          title: L("接缝转场 ") + tc(join.frame), first: origin, per: per, width: width)
                      }
                    }
                    if !transitionClips.isEmpty {
                      ForEach(
                        transitionClips.filter {
                          let origin = selected.contains($0.id) ? movedLeft : left
                          return ($0.startEffect != nil || $0.endEffect != nil)
                            && Double($0.end) >= origin && Double($0.start) <= origin + seen
                        }
                      ) { clip in
                        let origin = selected.contains(clip.id) ? movedLeft : left
                        ForEach(ClipEnd.allCases, id: \.self) { side in
                          if let effect = clip.effect(at: side), let range = clip.transitionRange(at: side) {
                            TransitionMarker(
                              editor: e, target: .edge(EdgeTarget(clipID: clip.id, end: side)),
                              effect: effect, range: range, anchor: side == .head ? clip.start : clip.end,
                              title: LKey(side.rawValue) + L("转场 ") + e.p.name(clip),
                              first: origin, per: per, width: width)
                          }
                        }
                      }
                      TransitionDropHighlight(
                        shelf: e.shelf, joins: laneJoins, clips: transitionClips, first: left, per: per, width: width)
                    }
                    Needle(t: e.transport, first: left, per: per).allowsHitTesting(false)
                  }.clipped()
                    .background(MarqueeTarget(id: lane.id, space: marqueeSpace))
                    .background {
                      if !transitionClips.isEmpty {
                        DropBandReader(
                          first: left, per: per, joins: laneJoins, clips: transitionClips,
                          viewport: viewport.frame(in: .named(DropBandKey.coordinateSpace)))
                      }
                    }
                }.frame(height: ClipLane.rowHeight(lane.kind)).padding(.trailing, 12)
                  .overlay(alignment: trackDrop?.after == true ? .bottom : .top) {
                    if trackDrop?.destination == lane.id {
                      Rectangle().fill(UI.accent).frame(height: 2).allowsHitTesting(false)
                    }
                  }
              }
              MarqueeBlank(selection: e.timelineMarquee) { e.selected = nil }
                .frame(height: max(0, viewport.size.height - lanes.reduce(0) {
                  $0 + ClipLane.rowHeight($1.kind) + 1
                }))
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
            .overlay { AlignmentLine(alignment: alignment, first: left, per: per, inset: head, width: width) }
        }
        if limit > 0.5 {
          HStack {
            Text(L("平移")).font(.caption2).foregroundStyle(UI.muted).frame(width: head)
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
