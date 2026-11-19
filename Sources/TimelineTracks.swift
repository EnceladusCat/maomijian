import Foundation

struct TimelineTrack: Identifiable {
  let title: String, kind: Kind, index: Int
  var clips: [Clip]
  var id: String { kind.rawValue + String(index) }
  var name: String { index == 0 ? title : "\(title) \(index + 1)" }
  var pinned: Bool { kind == .caption }
}

extension Project {
  func timelineTracks(joins: [Join]) -> [TimelineTrack] {
    orderedTracks(defaultTracks(joins: joins))
  }

  private func defaultTracks(joins: [Join]) -> [TimelineTrack] {
    var tracks: [TimelineTrack] = []
    for (kind, title) in [
      (Kind.caption, "字幕"), (.text, "标注"), (.zoom, "效果"), (.video, "视频"), (.audio, "音频"),
    ] {
      if kind == .video {
        tracks += videoLanes(joins).enumerated().map {
          TimelineTrack(title: title, kind: kind, index: $0.offset, clips: $0.element)
        }
        continue
      }
      var rows = [TimelineTrack(title: title, kind: kind, index: 0, clips: [])]
      let items = clips.filter { kind == .text ? $0.kind.isArt && $0.kind != .caption : $0.kind == kind }
        .sorted { $0.start < $1.start }
      for clip in items {
        if let i = rows.firstIndex(where: { ($0.clips.last?.end ?? 0) <= clip.start }) {
          rows[i].clips.append(clip)
        } else {
          rows.append(TimelineTrack(title: title, kind: kind, index: rows.count, clips: [clip]))
        }
      }
      tracks += rows
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
      if let neighbor = ordered.lastIndex(where: { $0.kind == track.kind }) {
        ordered.insert(track, at: neighbor + 1)
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
