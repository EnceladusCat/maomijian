import CoreGraphics
import Foundation

enum AudioVisualStyle: String, Codable, CaseIterable {
  case area, bars

  var title: String { self == .area ? L("面积波") : L("柱形") }
}

struct AudioVisualization: Codable, Equatable {
  var source: UUID?
  var style: AudioVisualStyle
  var followsSource = true
  var points = 44
  var seconds = 1.6
  var gain = 1.5
  var secondaryColor = "#7778EE"

  var valid: Bool {
    (12...96).contains(points) && (0.3...6).contains(seconds) && (0.1...6).contains(gain)
  }
}

extension Clip {
  var audioFamily: UUID { audioLink ?? id }
}

struct AudioVisualSource: Identifiable {
  let id: UUID
  let span: Range<Int>
  let name: String
}

extension Project {
  func audioVisualSources() -> [AudioVisualSource] {
    let audible = Set(assets.filter { $0.audio && !$0.isStill }.map(\.id))
    let eligible = clips.filter { $0.kind.isMedia && $0.asset.map(audible.contains) == true }
    let sources = Dictionary(grouping: eligible, by: \.audioFamily)
    return sources.map { id, parts in
      AudioVisualSource(id: id, span: parts.map(\.start).min()!..<parts.map(\.end).max()!, name: name(parts[0]))
    }.sorted { a, b in
      if a.span.lowerBound != b.span.lowerBound { return a.span.lowerBound < b.span.lowerBound }
      return a.id.uuidString < b.id.uuidString
    }
  }

  mutating func addAudioVisualization(for id: UUID, style: AudioVisualStyle) -> UUID? {
    guard let index = clips.firstIndex(where: { $0.id == id && $0.kind.isMedia }),
      asset(clips[index].asset)?.audio == true else { return nil }
    let family = clips[index].audioFamily
    clips[index].audioLink = family
    let spans = clips.filter { $0.kind.isMedia && $0.audioFamily == family }
    let start = spans.map(\.start).min()!
    let end = spans.map(\.end).max()!
    var visual = Clip(kind: .audioVisual, start: start, length: end - start)
    visual.audioVisualization = AudioVisualization(source: family, style: style)
    visual.color = "#9EEBC5"
    visual.w = 0.62
    visual.h = 0.15
    visual.y = 0.77
    clips.append(visual)
    return visual.id
  }

  mutating func linkAudioVisualization(_ id: UUID, to family: UUID) {
    guard let index = clips.firstIndex(where: { $0.id == id && $0.kind == .audioVisual }),
      let source = clips.firstIndex(where: { $0.kind.isMedia && $0.audioFamily == family }),
      asset(clips[source].asset)?.audio == true
    else { return }
    clips[source].audioLink = family
    clips[index].audioVisualization?.source = family
    clips[index].audioVisualization?.followsSource = true
  }

  mutating func syncAudioVisualizations() {
    guard clips.contains(where: { $0.audioVisualization?.source != nil }) else { return }
    var ranges = [UUID: Range<Int>]()
    for clip in clips where clip.kind.isMedia {
      let current = ranges[clip.audioFamily] ?? (clip.start..<clip.end)
      ranges[clip.audioFamily] = min(current.lowerBound, clip.start)..<max(current.upperBound, clip.end)
    }
    for index in clips.indices {
      guard let settings = clips[index].audioVisualization, let family = settings.source else { continue }
      if let range = ranges[family] {
        if settings.followsSource {
          clips[index].start = range.lowerBound
          clips[index].length = range.count
        }
      } else {
        clips[index].audioVisualization?.source = nil
        clips[index].audioVisualization?.followsSource = false
      }
    }
  }
}

struct AudioSignal {
  let clip: Clip
  let wave: AudioWaveform

  func level(from lower: Double, to upper: Double) -> Double {
    let origin = Double(clip.start)
    let a = max(lower, origin)
    let b = min(upper, Double(clip.end))
    guard b > a else { return 0 }
    let start = clip.sourceIn + (a - origin) * clip.effectiveRate
    let end = clip.sourceIn + (b - origin) * clip.effectiveRate
    return wave.peak(from: start, to: end) * clip.volume
  }
}

struct AudioSignalTrack {
  private let pieces: [AudioSignal]
  private let latestEnd: [Int]

  init(_ signals: [AudioSignal]) {
    pieces = signals.sorted { $0.clip.start < $1.clip.start }
    var end = 0
    latestEnd = pieces.map {
      end = max(end, $0.clip.end)
      return end
    }
  }

  func levels(at frame: Int, style: AudioVisualization) -> [Double] {
    let end = Double(frame + 1)
    let window = style.seconds * Double(fps)
    let start = end - window
    let stride = window / Double(style.points)
    var low = 0, high = latestEnd.count
    while low < high {
      let mid = (low + high) / 2
      if Double(latestEnd[mid]) <= start { low = mid + 1 } else { high = mid }
    }
    var levels = [Double](repeating: 0, count: style.points)
    for segment in pieces[low...] {
      if Double(segment.clip.start) >= end { break }
      let a = max(0, Int(floor((Double(segment.clip.start) - start) / stride)))
      let b = min(levels.count, Int(ceil((Double(segment.clip.end) - start) / stride)))
      guard a < b else { continue }
      for index in a..<b {
        let after = start + Double(index) * stride
        let level = segment.level(from: after, to: after + stride)
        levels[index] = max(levels[index], min(1, level * style.gain))
      }
    }
    return levels
  }
}

enum AudioVisualPaint {
  static func draw(_ values: [Double], style: AudioVisualization, color: String,
                   in rect: CGRect, context g: CGContext) {
    guard values.count > 1, rect.width > 0, rect.height > 0 else { return }
    let center = rect.midY
    let radius = rect.height * 0.46
    let minimum = max(0.5, rect.height * 0.009)
    let width = rect.width / Double(values.count)
    let shape = CGMutablePath()
    if style.style == .bars {
      for (index, value) in values.enumerated() {
        let h = max(minimum, radius * value)
        let bar = CGRect(x: rect.minX + (Double(index) + 0.18) * width, y: center - h,
                         width: width * 0.64, height: 2 * h)
        let r = min(bar.width / 2, h, rect.height * 0.027)
        shape.addRoundedRect(in: bar, cornerWidth: r, cornerHeight: r)
      }
    } else {
      let step = rect.width / Double(values.count - 1)
      func points(_ index: Int, _ side: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + Double(index) * step, y: center + side * max(minimum, values[index] * radius))
      }
      func trace(_ indices: [Int], side: CGFloat) {
        for (previous, next) in zip(indices, indices.dropFirst()) {
          let a = points(previous, side), b = points(next, side)
          let middle = (a.x + b.x) / 2
          shape.addCurve(to: b, control1: CGPoint(x: middle, y: a.y), control2: CGPoint(x: middle, y: b.y))
        }
      }
      shape.move(to: points(0, 1))
      trace(Array(values.indices), side: 1)
      shape.addLine(to: points(values.count - 1, -1))
      trace(Array(values.indices.reversed()), side: -1)
      shape.closeSubpath()
    }
    g.saveGState()
    g.addPath(shape)
    if let gradient = CGGradient(colorsSpace: rgb, colors: [ink(style.secondaryColor), ink(color)] as CFArray,
                                 locations: nil) {
      g.clip()
      g.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: center),
                           end: CGPoint(x: rect.maxX, y: center), options: [])
    } else {
      g.setFillColor(ink(color))
      g.fillPath()
    }
    g.restoreGState()
  }
}
