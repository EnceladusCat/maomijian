import Foundation

struct TimelineTrack: Identifiable {
  let title: String, kind: Kind, index: Int
  var clips: [Clip]
  var isInset = false
  var id: String { (isInset ? "pictureInset" : kind.rawValue) + String(index) }
  var name: String { index == 0 ? title : "\(title) \(index + 1)" }
  var pinned: Bool { kind == .caption }
}

/// Immutable timeline geometry for a project revision. Scrolling and dragging
/// query visible clips without packing every track or resolving media again.
struct TimelineLayout {
  struct Piece {
    let clip: Clip
    let name: String
    let hasAudio: Bool
  }

  struct Lane: Identifiable {
    let track: TimelineTrack
    let joins: [Project.Join]
    let transitionClips: [Clip]
    private let pieces: [Piece]
    private let furthestEnds: [Int]

    var id: String { track.id }
    var clipIDs: [UUID] { track.clips.map(\.id) }

    init(track: TimelineTrack, joins: [Project.Join], pieces: [Piece]) {
      self.track = track
      self.joins = joins
      self.pieces = pieces
      transitionClips = track.clips.filter { $0.kind.supportsTransitions }
      var end = 0
      furthestEnds = pieces.map {
        end = max(end, $0.clip.end)
        return end
      }
    }

    private func candidates(in viewport: ClosedRange<Double>) -> Range<Int> {
      let start = insertionIndex { Double(furthestEnds[$0]) < viewport.lowerBound }
      let end = insertionIndex { Double(pieces[$0].clip.start) <= viewport.upperBound }
      return start..<max(start, end)
    }

    private func insertionIndex(before: (Int) -> Bool) -> Int {
      var lower = 0
      var upper = pieces.count
      while lower < upper {
        let mid = (lower + upper) / 2
        if before(mid) { lower = mid + 1 } else { upper = mid }
      }
      return lower
    }

    func visible(in viewport: ClosedRange<Double>, selected: Set<UUID>, shift: Double) -> [Piece] {
      let regular = candidates(in: viewport)
      if shift == 0 {
        return regular.compactMap { index in
          let piece = pieces[index]
          return Double(piece.clip.end) >= viewport.lowerBound ? piece : nil
        }
      }
      let shifted = (viewport.lowerBound - shift)...(viewport.upperBound - shift)
      let moved = candidates(in: shifted)
      // Keep painting and overlapping-clip hit testing in the original lane order.
      var indices = IndexSet(integersIn: regular)
      indices.insert(integersIn: moved)
      return indices.compactMap { index in
        let piece = pieces[index]
        let range = selected.contains(piece.clip.id) ? shifted : viewport
        return Double(piece.clip.end) >= range.lowerBound && Double(piece.clip.start) <= range.upperBound
          ? piece : nil
      }
    }
  }

  let lanes: [Lane]
  let movableIDs: [String]
  let duration: Int
  let nextCaption: [UUID: UUID]

  init(_ project: Project) {
    let joins = project.joins
    let tracks = project.timelineTracks(joins: joins)
    let media = Dictionary(uniqueKeysWithValues: project.assets.map { ($0.id, $0) })
    var laneByClip = [UUID: Int]()
    for (index, track) in tracks.enumerated() {
      for clip in track.clips { laneByClip[clip.id] = index }
    }
    var joinsByLane = [[Project.Join]](repeating: [], count: tracks.count)
    for join in joins {
      if let index = laneByClip[join.after.id], laneByClip[join.before.id] == index {
        joinsByLane[index].append(join)
      }
    }
    lanes = tracks.enumerated().map { index, track in
      return Lane(track: track, joins: joinsByLane[index], pieces: track.clips.map { clip in
        let asset = clip.asset.flatMap { media[$0] }
        let name = clip.kind.isMedia ? asset?.name ?? clip.kind.title : project.name(clip)
        return Piece(clip: clip, name: name, hasAudio: asset?.audio == true)
      })
    }
    movableIDs = tracks.filter { !$0.pinned }.map(\.id)
    nextCaption = Dictionary(uniqueKeysWithValues: tracks.filter(\.pinned).flatMap { track in
      zip(track.clips, track.clips.dropFirst()).map { ($0.id, $1.id) }
    })
    duration = project.duration
  }
}

extension Project {
  func timelineTracks(joins: [Join]) -> [TimelineTrack] {
    orderedTracks(defaultTracks(joins: joins))
  }

  func annotationLanes() -> [[Clip]] { packedLanes(for: .text) }

  private func packedLanes(for kind: Kind) -> [[Clip]] {
    var lanes = [[Clip]()]
    let items = clips.filter { kind == .text ? $0.kind.isArt && $0.kind != .caption : $0.kind == kind }
      .sorted { $0.start < $1.start }
    for clip in items {
      if let index = lanes.firstIndex(where: { ($0.last?.end ?? 0) <= clip.start }) {
        lanes[index].append(clip)
      } else {
        lanes.append([clip])
      }
    }
    return lanes
  }

  private func defaultTracks(joins: [Join]) -> [TimelineTrack] {
    var tracks: [TimelineTrack] = []
    for (kind, title) in [
      (Kind.caption, L("字幕")), (.text, L("标注")), (.zoom, L("效果")), (.video, L("视频")), (.audio, L("音频")),
    ] {
      if kind == .video {
        tracks += videoLanes(joins).enumerated().map {
          TimelineTrack(title: title, kind: kind, index: $0.offset, clips: $0.element)
        }
        continue
      }
      tracks += packedLanes(for: kind).enumerated().map {
        TimelineTrack(title: title, kind: kind, index: $0.offset, clips: $0.element)
      }
      if kind == .caption {
        tracks += videoLanes(joins, insets: true).enumerated().map {
          TimelineTrack(title: L("画中画"), kind: .video, index: $0.offset, clips: $0.element, isInset: true)
        }
      }
    }
    return tracks
  }

  func visualTrackDepth() -> [UUID: Int]? {
    guard trackOrder != nil else { return nil }
    let visual = defaultTracks(joins: joins).filter { !$0.pinned && $0.kind != .audio }
    let reordered = orderedTracks(visual)
    return Dictionary(uniqueKeysWithValues: reordered.enumerated().flatMap { depth, track in
      track.clips.map { ($0.id, depth) }
    })
  }

  private func orderedTracks(_ tracks: [TimelineTrack]) -> [TimelineTrack] {
    guard let trackOrder else { return tracks }
    let movable = tracks.filter { !$0.pinned }
    var remaining = Dictionary(uniqueKeysWithValues: movable.map { ($0.id, $0) })
    var ordered = trackOrder.compactMap { remaining.removeValue(forKey: $0) }
    for track in movable where remaining[track.id] != nil {
      if let neighbor = ordered.lastIndex(where: { $0.kind == track.kind && $0.isInset == track.isInset }) {
        ordered.insert(track, at: neighbor + 1)
      } else if track.isInset {
        ordered.insert(track, at: 0)
      } else {
        ordered.append(track)
      }
    }
    return tracks.filter(\.pinned) + ordered
  }

  mutating func moveTrack(_ id: String, to destination: String) {
    var ids = timelineTracks(joins: joins).filter { !$0.pinned }.map(\.id)
    guard let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: destination), from != to
    else { return }
    ids.remove(at: from)
    ids.insert(id, at: to)
    trackOrder = ids
  }
}
