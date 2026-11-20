import Foundation

enum BatchCutMode: String, CaseIterable {
  case interval = "固定间隔"
  case count = "均分份数"
}
struct BatchCutSettings: Equatable {
  var mode = BatchCutMode.interval
  var interval = 1.0
  var limit = 0
  var count = 10
}
struct BatchAdjustment {
  var time = 0.0
  var x = 0.0
  var y = 0.0
  var scale = 100.0
}
extension Kind {
  var supportsBatchPosition: Bool { self != .audio }
  var supportsBatchScale: Bool { supportsBatchPosition && self != .caption }
}
struct BatchPart: Identifiable {
  let id: Int
  let original: Clip
  let ordinal: Int
  let range: Range<Int>
  var adjustments = BatchAdjustment()
}

struct BatchCutPlan {
  static let partLimit = 10_000
  var parts: [BatchPart] = []
  var remainders: [UUID: Range<Int>] = [:]

  init(clips: [Clip], settings: BatchCutSettings) throws {
    guard !clips.isEmpty else {
      throw EditError.message(L("请在时间线上选择要切割的片段。"))
    }
    guard (1 / Double(fps)...Double(maxFrames) / Double(fps)).contains(settings.interval),
      (0...Self.partLimit).contains(settings.limit), (2...Self.partLimit).contains(settings.count)
    else { throw EditError.message(L("请填写有效的间隔或份数。")) }

    let step = max(1, Int((settings.interval * Double(fps)).rounded()))
    for clip in clips {
      let count: Int
      switch settings.mode {
      case .interval:
        let total = (clip.length + step - 1) / step
        count = settings.limit == 0 ? total : min(settings.limit, total)
      case .count:
        guard settings.count <= clip.length else {
          throw EditError.message(L("至少一个所选片段的帧数少于设定的份数。"))
        }
        count = settings.count
      }
      guard parts.count + count <= Self.partLimit else {
        throw EditError.message(L("本次会生成超过 10,000 份。请增大间隔或减少选中的素材。"))
      }
      for index in 0..<count {
        let start = boundary(
          index, count: count, length: clip.length, step: step, mode: settings.mode)
        let end = boundary(
          index + 1, count: count, length: clip.length, step: step, mode: settings.mode)
        let range = (clip.start + start)..<(clip.start + end)
        parts.append(BatchPart(id: parts.count, original: clip, ordinal: index, range: range))
      }
      if let end = parts.last?.range.upperBound, end < clip.end {
        remainders[clip.id] = end..<clip.end
      }
    }
  }

  private func boundary(_ i: Int, count: Int, length: Int, step: Int, mode: BatchCutMode) -> Int {
    switch mode {
    case .interval: return min(length, i * step)
    case .count: return (i * length + count / 2) / count
    }
  }
}

extension Project {
  func applying(_ plan: BatchCutPlan) throws -> (project: Project, selected: [UUID]) {
    var next = self
    var replacements = [UUID: [(clip: Clip, formerStart: Int)]]()
    var selection: [UUID] = []
    for part in plan.parts {
      let c = part.original
      var result = c.segment(part.range, timedSource: asset(c.asset)?.isStill != true)
      let changes = part.adjustments
      let label = name(c) + L(" 第\(part.ordinal + 1)份")
      let frameDelta = changes.time * Double(fps)
      guard (-Double(maxFrames)..<Double(maxFrames)).contains(frameDelta) else {
        throw EditError.message(label + L("的时间位移超出范围。"))
      }
      // Snap numerical noise around half-frames so linear rules round consistently.
      let halfFrame = (frameDelta * 2).rounded() / 2
      let delta = abs(frameDelta - halfFrame) < 1e-8 ? halfFrame : frameDelta
      result.start += Int(delta.rounded())
      guard result.start >= 0, result.end <= maxFrames else {
        throw EditError.message(label + L("移动后超出时间线范围。"))
      }
      try result.applyBatchTransform(changes, label: label)
      replacements[c.id, default: []].append((result, part.range.lowerBound))
      selection.append(result.id)
    }
    for (id, range) in plan.remainders {
      guard let c = clips.first(where: { $0.id == id }) else { continue }
      let tail = c.segment(range, timedSource: asset(c.asset)?.isStill != true)
      replacements[id, default: []].append((tail, range.lowerBound))
    }

    let pieces = clips.flatMap { replacements[$0.id] ?? [(clip: $0, formerStart: $0.start)] }
    next.clips = pieces.map { piece in
      var c = piece.clip
      if let from = c.from, let split = replacements[from],
        let before = split.last(where: { $0.formerStart < piece.formerStart })
      {
        c.from = before.clip.id
      }
      if let followers = c.transitionFollowers {
        c.transitionFollowers = followers.flatMap { id in
          replacements[id].map { $0.map(\.clip.id) } ?? [id]
        }
      }
      return c
    }
    return (try next.checked(), selection)
  }
}

private extension Clip {
  mutating func applyBatchTransform(_ changes: BatchAdjustment, label: String) throws {
    if kind.supportsBatchPosition {
      x += changes.x / 100
      y += changes.y / 100
      let valid = kind == .video ? -4.0...5.0 : 0...1
      guard valid.contains(x), valid.contains(y) else {
        throw EditError.message(label + L("的画布位置超出范围。"))
      }
    }
    guard kind.supportsBatchScale, changes.scale != 100 else { return }
    let factor = changes.scale / 100
    if kind == .video {
      let resized = displayScale * factor
      guard (0.05...8).contains(resized) else {
        throw EditError.message(label + L("的最终缩放须在 5% 至 800% 之间。"))
      }
      visualScale = resized
    } else {
      let limit = kind.isRegion ? 1.0 : 2.0
      guard (0.01...limit).contains(w * factor), (0.01...limit).contains(h * factor) else {
        throw EditError.message(label + L("缩放后的尺寸超出范围。"))
      }
      if let appearance = textAppearance, appearance.usesFixedSize {
        let pointSize = appearance.size * factor
        guard pointSize.isFinite, pointSize >= 8 else {
          throw EditError.message(label + L("缩放后的字号超出范围。"))
        }
        textAppearance?.size = pointSize
        textAppearance?.fixedSize = true
      }
      w *= factor
      h *= factor
    }
  }
}
