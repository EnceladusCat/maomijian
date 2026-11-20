import Foundation

struct TimelineClipboard: Codable {
  let clips: [Clip]
  let assets: [Media]

  init(project: Project, selection: [UUID]) {
    let ids = Set(project.expandingGroups(selection))
    clips = project.clips.filter { ids.contains($0.id) }
    let usedAssets = Set(clips.compactMap(\.asset))
    assets = project.assets.filter { usedAssets.contains($0.id) }
  }

  func paste(into project: inout Project, at start: Int) throws -> [UUID] {
    guard !clips.isEmpty else { return [] }
    var copied = Project()
    copied.assets = assets
    copied.clips = clips
    try _ = copied.checked()
    guard let first = clips.map(\.start).min(), start >= 0,
      start <= maxFrames - (copied.duration - first)
    else { throw EditError.message(L("粘贴的片段超出工程时长上限。")) }

    let existing = Dictionary(uniqueKeysWithValues: project.assets.map { ($0.id, $0) })
    var mediaIDs: [UUID: UUID] = [:]
    for asset in assets {
      var added = asset
      if let original = existing[asset.id], original != asset { added.id = UUID() }
      mediaIDs[asset.id] = added.id
      if existing[added.id] == nil { project.assets.append(added) }
    }
    let clipIDs = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, UUID()) })
    let families = Set(clips.filter { $0.kind.isMedia }.compactMap(\.audioLink))
    let newFamilies = Dictionary(uniqueKeysWithValues: families.map { ($0, UUID()) })
    let existingFamilies = Set(project.clips.filter { $0.kind.isMedia }.map(\.audioFamily))
    let groups = Dictionary(grouping: clips.compactMap(\.groupID), by: { $0 })
      .compactMapValues { $0.count > 1 ? UUID() : nil }
    let pasted = clips.map { clip in
      var next = clip
      next.id = clipIDs[clip.id]!
      next.start = start + (clip.start - first)
      next.asset = clip.asset.flatMap { mediaIDs[$0] }
      next.audioLink = clip.audioLink.flatMap { newFamilies[$0] }
      if let source = next.audioVisualization?.source {
        if let copied = newFamilies[source] {
          next.audioVisualization?.source = copied
        } else {
          next.audioVisualization?.source = existingFamilies.contains(source) ? source : nil
          next.audioVisualization?.followsSource = false
        }
      }
      next.groupID = clip.groupID.flatMap { groups[$0] }
      next.from = clip.from.flatMap { clipIDs[$0] }
      if clip.from != nil && next.from == nil {
        next.fixedCutOffset = nil
        next.blend = 0
        next.transitionLook = nil
      }
      let followers = clip.transitionFollowers?.compactMap { clipIDs[$0] } ?? []
      next.transitionFollowers = followers.isEmpty ? nil : followers
      return next
    }
    project.clips += pasted
    project.syncAudioVisualizations()
    return pasted.map(\.id)
  }
}

extension Clip {
  private var hasTypography: Bool { kind == .text || kind == .timer }

  func acceptsProperties(from source: Clip, sharedAudio: Bool) -> Bool {
    sharedAudio || (kind != .audio && source.kind != .audio)
  }

  mutating func applyProperties(from source: Clip, sharedAudio: Bool = false) {
    if sharedAudio {
      volume = source.volume
      pitchSemitones = source.pitchSemitones
    }
    guard kind != .audio && source.kind != .audio else { return }
    let originalInset = kind == .video && source.pictureInset != nil
      ? pictureInset ?? PictureInset(self) : nil

    x = kind == .video ? source.x : bound(source.x, 0, 1)
    y = kind == .video ? source.y : bound(source.y, 0, 1)
    if kind.isRegion && source.kind.isRegion {
      w = source.w
      h = source.h
      regionShape = source.regionShape
      if kind == .highlight && source.kind == .highlight {
        opacity = source.opacity
        highlightFadeIn = source.highlightFadeIn
        highlightFadeOut = source.highlightFadeOut
      }
      if kind == .zoom && source.kind == .zoom {
        scale = source.scale
        borderColor = source.borderColor
        lensBorderWidth = source.lensBorderWidth
        zoomInFrames = source.zoomInFrames
        zoomOutFrames = source.zoomOutFrames
      }
    }
    guard !kind.isRegion && !source.kind.isRegion else { return }
    if kind.isArt && source.kind.isArt {
      w = source.w
      h = source.h
      if kind != .caption && source.kind != .caption { color = source.color }
    }
    angle = source.angle
    opacity = source.opacity
    if supportsMotion && source.supportsMotion {
      motion = source.motion
      motionFrames = source.motionFrames
      motionContinuous = source.motionContinuous
      shakeAmplitude = source.shakeAmplitude
      shakeFrequency = source.shakeFrequency
      motionZoom = source.motionZoom
      motionPath = source.motionPath
      slideFrames = source.slideFrames
    }
    if kind == .video && source.kind == .video {
      visualScale = source.visualScale
      sourceCrop = source.sourceCrop
      visualBorder = source.visualBorder
      pictureInset = originalInset
      if let shape = source.pictureInset?.shape { pictureInset?.shape = shape }
      filters = source.filters
    }
    if hasTypography && source.hasTypography { textAppearance = source.textAppearance }
    if kind == .text && source.kind == .text { textAnimation = source.textAnimation }
    if kind == .chart && source.kind == .chart {
      chartAppearance = source.chartAppearance
      if let frames = source.chart?.entryFrames { chart?.entryFrames = frames }
    }
    if kind == .audioVisual, var visual = source.audioVisualization {
      visual.source = audioVisualization?.source
      visual.followsSource = audioVisualization?.followsSource ?? false
      audioVisualization = visual
    }
    if kind.supportsRelief && source.kind.supportsRelief { reliefStyle = source.reliefStyle }
    if kind.supportsShapeAppearance && source.kind.supportsShapeAppearance {
      shapeAppearance = source.shapeAppearance
    }
  }
}
