import AVFoundation
import SwiftUI

/// Decodes a small source frame while the playhead moves, then draws the
/// existing composition at that time. AVPlayer retains the last full frame
/// and does its frame-accurate seek when the pointer is released.
final class ScrubPreview: ObservableObject {
  struct Frame {
    let number: Int
    let image: CGImage
  }

  final class Source {
    let generator: AVAssetImageGenerator
    private(set) var used = false

    func markUsed() { used = true }

    init(_ path: String, size: CGSize) {
      generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
      generator.maximumSize = CGSize(width: max(size.width, size.height), height: max(size.width, size.height))
      generator.appliesPreferredTrackTransform = false
    }
  }

  struct Request {
    let frame: Int
    let slice: Slice
    let clip: Clip
    let source: Source
    let transform: CGAffineTransform
    let bounds: Range<Int>
    let painter: FramePainter

    func moving(to frame: Int) -> Self {
      Self(frame: frame, slice: slice, clip: clip, source: source, transform: transform,
           bounds: bounds, painter: painter)
    }

    func render() async -> Frame? {
      let lower = max(bounds.lowerBound, frame - 12)
      let upper = min(bounds.upperBound - 1, frame + 12)
      guard lower <= frame, upper >= frame else { return nil }
      let sourceFrame = clip.sourceFrame(at: frame)
      let sourceTime = CMTime(seconds: sourceFrame / Double(fps), preferredTimescale: 600_000)
      let generator = source.generator
      generator.requestedTimeToleranceBefore = CMTime(
        seconds: (sourceFrame - clip.sourceFrame(at: lower)) / Double(fps), preferredTimescale: 600_000)
      generator.requestedTimeToleranceAfter = CMTime(
        seconds: (clip.sourceFrame(at: upper) - sourceFrame) / Double(fps), preferredTimescale: 600_000)
      guard let decoded = try? await generator.image(at: sourceTime), !Task.isCancelled else { return nil }
      let sourceOffset = (decoded.actualTime - sourceTime).seconds
      guard sourceOffset.isFinite else { return nil }
      let actual = bound(frame + Int((sourceOffset * Double(fps) / clip.effectiveRate).rounded()), lower, upper)
      let picture = Picture(image: decoded.image, transform: transform)
      guard let context = bitmap(Int(painter.size.width), Int(painter.size.height)) else { return nil }
      painter.paint(context, frame: actual, active: slice.clips) { id in
        id == clip.id ? picture : nil
      }
      guard let image = context.makeImage() else { return nil }
      return Frame(number: actual, image: image)
    }
  }

  @Published private(set) var frame: Frame?
  // A single decode per generator. Retain the most recent pointer target
  // without cancelling the hardware decoder every time the mouse moves.
  private var running = false
  private var next: Request?
  private var session: UUID?
  private var latestTarget: ((Int) -> Request?)?
  private(set) var decodeDelay = 0.028
  private var onFailure: ((Int) -> Void)?

  func update(
    _ request: Request, session id: UUID,
    latest: @escaping (Int) -> Request?, failure: @escaping (Int) -> Void
  ) {
    session = id
    latestTarget = latest
    onFailure = failure
    next = request
    decodeNext()
  }

  // Prime the decoder using normal playback time, without displaying a frame.
  func warm(_ source: Source, at frame: Double) {
    guard !source.used, !running, session == nil else { return }
    source.markUsed()
    running = true
    let work = Task.detached(priority: .utility) {
      let tolerance = CMTime(seconds: 0.4, preferredTimescale: 600)
      source.generator.requestedTimeToleranceBefore = tolerance
      source.generator.requestedTimeToleranceAfter = tolerance
      _ = try? await source.generator.image(
        at: CMTime(seconds: frame / Double(fps), preferredTimescale: 600_000))
    }
    Task { @MainActor [weak self] in
      await work.value
      guard let self else { return }
      self.running = false
      self.decodeNext()
    }
  }

  func stopKeepingImage() {
    session = nil
    next = nil
    latestTarget = nil
    onFailure = nil
  }

  func clear() {
    stopKeepingImage()
    if frame != nil { frame = nil }
  }

  private func decodeNext() {
    guard !running, let request = next, let id = session else { return }
    running = true
    request.source.markUsed()
    next = nil
    let adjusted = latestTarget?(request.frame) ?? request
    let started = CACurrentMediaTime()
    let work = Task.detached(priority: .userInitiated) { await adjusted.render() }
    Task { @MainActor [weak self] in
      let updated = await work.value
      guard let self else { return }
      self.running = false
      if self.session == id {
        if let updated {
          let delay = bound(CACurrentMediaTime() - started, 0.008, 0.070)
          self.decodeDelay = 0.7 * self.decodeDelay + 0.3 * delay
          if self.frame?.number != updated.number { self.frame = updated }
        } else if self.next == nil {
          self.onFailure?(request.frame)
        }
      }
      self.decodeNext()
    }
  }
}

struct ScrubPreviewOverlay: View {
  @ObservedObject var preview: ScrubPreview

  var body: some View {
    if let frame = preview.frame {
      Image(decorative: frame.image, scale: 1).resizable().allowsHitTesting(false)
    }
  }
}
