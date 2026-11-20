import Foundation

struct RecoveryDraft: Codable {
  var project: Project
  var original: URL?
  var frame: Int
  var savedAt: Date
}

final class ProjectRecovery {
  private let file: URL
  private let writer = DispatchQueue(label: "framecut.recovery", qos: .utility)
  private var pending: DispatchWorkItem?
  private var latest: RecoveryDraft?
  private var revision = 0

  init(file: URL? = nil) {
    let support = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
    self.file = file ?? support
      .appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.framecut.editor", isDirectory: true)
      .appendingPathComponent("Recovery.json")
  }

  func load() throws -> RecoveryDraft? {
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    let data = try Data(contentsOf: file)
    var draft = try JSONDecoder().decode(RecoveryDraft.self, from: data)
    for index in draft.project.assets.indices {
      if let sound = draft.project.assets[index].soundID,
        let current = BuiltInSound(rawValue: sound)?.url
      {
        draft.project.assets[index].path = current.path
      }
    }
    draft.project = try draft.project.checked()
    draft.frame = bound(draft.frame, 0, draft.project.duration)
    return draft
  }

  func schedule(_ draft: RecoveryDraft, failure: @escaping (Error) -> Void) {
    latest = draft
    guard pending == nil else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self, let draft = self.latest else { return }
      self.pending = nil
      self.latest = nil
      let revision = self.revision
      let file = self.file
      self.writer.async {
        do {
          try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
          try JSONEncoder().encode(draft).write(to: file, options: .atomic)
        } catch {
          DispatchQueue.main.async { [weak self] in
            guard self?.revision == revision else { return }
            failure(error)
          }
        }
      }
    }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
  }

  func discard() {
    revision += 1
    pending?.cancel()
    pending = nil
    latest = nil
    writer.sync {
      if FileManager.default.fileExists(atPath: file.path) {
        try? FileManager.default.removeItem(at: file)
      }
    }
  }
}
