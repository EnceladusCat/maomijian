import Foundation

struct TimelineTrack: Identifiable {
  let title: String, kind: Kind, index: Int
  var clips: [Clip]
  var isInset = false
  var id: String { (isInset ? "pictureInset" : kind.rawValue) + String(index) }
  var name: String { index == 0 ? title : "\(title) \(index + 1)" }
  var pinned: Bool { kind == .caption }
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
