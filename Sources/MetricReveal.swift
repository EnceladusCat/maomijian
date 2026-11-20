import Foundation

enum MetricRevealMode: String, Codable, CaseIterable {
  case share, comparison

  var title: String { self == .share ? L("占比") : L("对比") }
}

struct MetricReveal: Codable, Equatable {
  var enabled = true
  var mode = MetricRevealMode.share
  var scale = 100.0
  var offsetFrames = 12
  var durationFrames = 18

  init(clipLength: Int) {
    offsetFrames = min(offsetFrames, clipLength - 1)
    durationFrames = min(durationFrames, clipLength - offsetFrames)
  }

  var valid: Bool {
    (0.001...1e12).contains(scale) && (-maxFrames...maxFrames).contains(offsetFrames)
      && (0...maxFrames).contains(durationFrames)
  }

  func progress(at localFrame: Int) -> Double {
    guard localFrame >= offsetFrames else { return 0 }
    return min(1, Double(localFrame - offsetFrames + 1) / Double(max(1, durationFrames)))
  }

  func exitSpan(requested: Int, lastFrame: Int) -> Int {
    let revealed = offsetFrames + max(1, durationFrames) - 1
    let wait = offsetFrames > lastFrame ? 0 : max(0, revealed)
    return min(requested, max(0, lastFrame - wait))
  }

  func bar(from start: Double, to target: Double, showing current: Double) -> MetricRevealBar {
    let upper = max(scale, abs(start), abs(target))
    let lower = min(start, target) < 0 ? -upper : 0
    func position(_ value: Double) -> Double { (value - lower) / (upper - lower) }
    return MetricRevealBar(
      lower: lower, upper: upper, zero: position(0), baseline: position(start), current: position(current))
  }
}

struct MetricRevealBar: Equatable {
  let lower: Double, upper: Double, zero: Double, baseline: Double, current: Double
  var accent: ClosedRange<Double> { min(baseline, current)...max(baseline, current) }
}

extension Project {
  func metricClipForQuickEdit(selected: UUID?, at frame: Int) -> Clip? {
    if let selected, let clip = clips.first(where: { $0.id == selected && $0.editorial?.style == .metric }) {
      return clip
    }
    return clips.last { $0.editorial?.style == .metric && ($0.start..<$0.end).contains(frame) }
  }

  @discardableResult mutating func useQuickMetricStyle(reveal: Bool, selected: UUID?, at frame: Int) -> UUID {
    if let target = metricClipForQuickEdit(selected: selected, at: frame),
       let index = clips.firstIndex(where: { $0.id == target.id })
    {
      clips[index].editorial?.useMetricReveal(reveal, clipLength: target.length)
      return target.id
    }

    var clip = EditorialStyle.metric.clip(at: frame)
    if let next = clips.filter({ $0.editorial?.style == .metric && $0.start > frame }).map(\.start).min() {
      clip.length = min(clip.length, next - frame)
    }
    if reveal {
      clip.text = L("收入占比")
      clip.editorial?.useMetricReveal(true, clipLength: clip.length)
      clip.editorial?.metricAppearance = EditorialMetricAppearance(unitSize: 0.57)
    }
    clips.append(clip)
    return clip.id
  }
}
