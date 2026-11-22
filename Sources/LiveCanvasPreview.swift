import AVFoundation
import SwiftUI

struct CanvasFrame {
  let number: Int
  let painter: FramePainter
  let clips: [Clip]
  let pictures: [UUID: Picture]
  var captions: [Clip] = []

  func image(with draft: Clip) -> CGImage? {
    guard clips.contains(where: { $0.id == draft.id }) || captions.contains(where: { $0.id == draft.id }),
      let context = bitmap(Int(painter.size.width), Int(painter.size.height))
    else { return nil }
    painter.paint(
      context, frame: number, active: clips.map { $0.id == draft.id ? draft : $0 }
    ) { pictures[$0] }
    if !captions.isEmpty {
      painter.paintCaptions(context, frame: number, active: captions.map { $0.id == draft.id ? draft : $0 })
    }
    return context.makeImage()
  }
}

final class CanvasFrames {
  private let lock = NSLock()
  private var recent: [CanvasFrame] = []

  func store(_ frame: CanvasFrame) {
    lock.withLock {
      recent.removeAll { $0.number == frame.number }
      recent.append(frame)
      if recent.count > 2 { recent.removeFirst() }
    }
  }
  func frame(_ number: Int) -> CanvasFrame? {
    lock.withLock { recent.last { $0.number == number } }
  }
}

// The draft reuses the decoded pictures of one paused frame. Only the newest
// pointer position waits for the renderer, and the project changes on release.
final class LiveCanvasPreview: ObservableObject {
  private struct Request {
    let draft: Clip
    let frame: Int
    let composition: Composition
  }

  @Published private(set) var image: CGImage?
  @Published private(set) var captionDraft: Clip?
  private(set) var activeID: UUID?
  private let queue = DispatchQueue(label: "framecut.canvas.draft", qos: .userInteractive)
  private var token = UUID()
  private var rendering = false
  private var latest: Request?
  private var finalDraft: Clip?
  private var displayedDraft: Clip?

  func update(_ draft: Clip, frame: Int, composition: Composition) {
    if activeID != draft.id {
      resetRequests()
      if captionDraft != nil { captionDraft = nil }
      activeID = draft.id
    }
    if draft.kind == .caption, composition.captionPreview(at: frame) != nil {
      captionDraft = draft
      return
    }
    latest = Request(draft: draft, frame: frame, composition: composition)
    renderLatest()
  }

  private func renderLatest() {
    guard !rendering, let request = latest else { return }
    latest = nil
    if displayedDraft == request.draft { return }
    rendering = true
    let revision = token
    queue.async { [weak self] in
      let image = autoreleasepool {
        request.composition.canvasFrame(at: request.frame)?.image(with: request.draft)
      }
      DispatchQueue.main.async {
        guard let self, self.token == revision else { return }
        self.rendering = false
        if let image, self.finalDraft == nil || self.finalDraft == request.draft {
          self.displayedDraft = request.draft
          self.image = image
        }
        self.renderLatest()
      }
    }
  }

  func end(with draft: Clip, frame: Int, composition: Composition) {
    activeID = nil
    if draft.kind == .caption, composition.captionPreview(at: frame) != nil {
      captionDraft = draft
      return
    }
    finalDraft = draft
    // Keep the committed still visible while paused. A seek completing at the
    // same timestamp does not guarantee the player layer has swapped images.
    latest = Request(draft: draft, frame: frame, composition: composition)
    renderLatest()
  }

  func clear() {
    resetRequests()
    displayedDraft = nil
    if image != nil { image = nil }
    if captionDraft != nil { captionDraft = nil }
  }

  func clearCommittedCaption() {
    if activeID == nil, captionDraft != nil { captionDraft = nil }
  }

  private func resetRequests() {
    token = UUID()
    activeID = nil
    rendering = false
    latest = nil
    finalDraft = nil
  }
}

struct LiveCanvasOverlay: View {
  @ObservedObject var preview: LiveCanvasPreview
  var body: some View {
    if let image = preview.image {
      Image(decorative: image, scale: 1).resizable().allowsHitTesting(false)
    }
  }
}
