import Foundation
import SwiftUI

enum VoiceoverText: String, CaseIterable {
  case original = "字幕原文"
  case translation = "译文"
  case instant = "即转"

  func text(in clip: Clip) -> String {
    let value: String
    switch self {
    case .original: value = clip.text
    case .translation: value = clip.captionTranslation ?? ""
    case .instant: return ""
    }
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

struct VoiceoverCue: Equatable {
  let id: UUID
  let start: Int
  let length: Int
  let text: String

  init(_ clip: Clip, source: VoiceoverText) {
    id = clip.id
    start = clip.start
    length = clip.length
    text = source.text(in: clip)
  }

  func audioClip(using media: Media) -> Clip {
    let length = min(media.frames, max(self.length, (media.frames + 1) / 2))
    var clip = Clip(kind: .audio, asset: media.id, start: start,
                    length: min(length, maxFrames - start))
    // Preserve the full reading whenever fitting needs no more than 2× speed.
    let available = min(media.frames, clip.length * 2)
    if available > clip.length {
      clip.setSource(0, Double(available))
      clip.speed = clip.effectiveRate
    }
    return clip
  }
}

final class CaptionVoiceover: ObservableObject {
  enum Stage: Equatable {
    case preparing, downloading(Double), registering, synthesizing(Int, Int)
  }

  struct Output {
    let assets: [Media]
    let clips: [Clip]

    func discard() {
      if let media = assets.first {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: media.path).deletingLastPathComponent())
      }
    }
  }

  typealias Report = (Stage) async -> Void
  @Published var instantText = ""
  @Published private(set) var stage: Stage?
  @Published private(set) var notice = ""
  @Published private(set) var profiles = VoiceoverProfile.load(in: support)
  private var job: Task<Void, Never>?

  private static var support: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.framecut.editor")
  }

  private static var resources: URL? {
    Bundle.main.resourceURL?.appendingPathComponent("Audio8", isDirectory: true)
  }

  static var available: Bool {
    guard let resources else { return false }
    return FileManager.default.isExecutableFile(atPath: interpreter(in: resources).path)
  }

  private static func interpreter(in resources: URL) -> URL {
    resources.appendingPathComponent("python/bin/python3")
  }

  func cancel() { job?.cancel() }

  func start(
    _ cues: [VoiceoverCue], voice: VoiceoverProfile?, accept: @escaping (Output) -> String
  ) {
    guard !cues.isEmpty, let resources = Self.resources else { return }
    let support = Self.support
    perform(discard: { $0.discard() }, work: { report in
      try await Self.render(cues, voice: voice, resources: resources, support: support, report: report)
    }, accept: accept)
  }

  func exportText(
    _ text: String, voice: VoiceoverProfile?, to destination: URL,
    validate: @escaping () throws -> Void
  ) {
    guard let resources = Self.resources else { return }
    let support = Self.support
    perform(discard: { _ in }, work: { report in
      try await Self.renderText(text, voice: voice, to: destination,
                                resources: resources, support: support, report: report)
    }, accept: { file in
      do {
        try validate()
        try ExportJob.commit(file.url, destination)
        return L("已导出 ") + destination.lastPathComponent
      } catch { return error.localizedDescription }
    })
  }

  func register(name: String, transcript: String, recording: URL, saved: @escaping (VoiceoverProfile) -> Void) {
    guard let resources = Self.resources else { return }
    let profile = VoiceoverProfile(
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      referenceText: transcript.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !profile.name.isEmpty, !profile.referenceText.isEmpty else { return }
    let support = Self.support
    perform(discard: { try? FileManager.default.removeItem(at: $0.folder(in: support)) }, work: { report in
      try await Self.register(profile, recording: recording, resources: resources, support: support, report: report)
      return profile
    }, accept: { [weak self] profile in
      self?.profiles = VoiceoverProfile.load(in: support)
      saved(profile)
      return L("已保存音色「\(profile.name)」。")
    })
  }

  func remove(_ profile: VoiceoverProfile) {
    guard job == nil else { return }
    do {
      try FileManager.default.removeItem(at: profile.folder(in: Self.support))
      profiles.removeAll { $0.id == profile.id }
      notice = L("已移除自定义音色。")
    } catch { notice = error.localizedDescription }
  }

  private func perform<T>(
    discard: @escaping (T) -> Void, work: @escaping (Report) async throws -> T,
    accept: @escaping (T) -> String
  ) {
    guard job == nil else { return }
    stage = .preparing
    notice = ""
    job = Task.detached(priority: .utility) { [weak self] in
      let result: Result<T, Error>
      do {
        let report: Report = { [weak self] stage in
          await MainActor.run {
            guard let self, self.stage != stage else { return }
            self.stage = stage
          }
        }
        result = .success(try await work(report))
      } catch {
        result = .failure(error)
      }
      await MainActor.run {
        guard let self else {
          if case .success(let output) = result { discard(output) }
          return
        }
        let cancelled = self.job?.isCancelled == true
        self.job = nil
        self.stage = nil
        if cancelled {
          if case .success(let output) = result { discard(output) }
          self.notice = L("已停止配音任务")
        } else {
          switch result {
          case .success(let output): self.notice = accept(output)
          case .failure(let error): self.notice = error.localizedDescription
          }
        }
      }
    }
  }

  private struct Request: Encodable {
    let text: String
    let path: String
  }

  static func renderText(
    _ text: String, voice: VoiceoverProfile?, to destination: URL, resources: URL, support: URL,
    scratch: MediaScratch = .shared, report: Report
  ) async throws -> MediaScratch.File {
    let staged = try scratch.make(.wav, beside: destination.deletingLastPathComponent())
    let request = Request(text: text, path: staged.url.path)
    try await synthesize(request, total: nil, voice: voice, resources: resources, support: support,
                         scratch: scratch, report: report)
    let audio = try inspect(staged.url)
    guard audio.audio, !audio.video else { throw CocoaError(.fileReadCorruptFile) }
    return staged
  }

  static func render(
    _ cues: [VoiceoverCue], voice: VoiceoverProfile? = nil, resources: URL, support: URL,
    scratch: MediaScratch = .shared, report: Report
  ) async throws -> Output {
    var audio: [MediaScratch.File] = []
    var entries: [Request] = []
    var byText: [String: Int] = [:]
    for cue in cues where byText[cue.text] == nil {
      let file = try scratch.make(.wav)
      byText[cue.text] = entries.count
      entries.append(Request(text: cue.text, path: file.url.path))
      audio.append(file)
    }
    try await synthesize(entries, total: entries.count, voice: voice, resources: resources,
                         support: support, scratch: scratch, report: report)

    let fm = FileManager.default
    let destination = support.appendingPathComponent("Voiceovers").appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    do {
      let assets = try audio.enumerated().map { index, file -> Media in
        try Task.checkCancellation()
        var asset = try inspect(file.url)
        guard asset.audio, !asset.video else { throw CocoaError(.fileReadCorruptFile) }
        let name = L("字幕配音 \(index + 1)") + ".wav"
        let target = destination.appendingPathComponent(name)
        try fm.moveItem(at: file.url, to: target)
        asset.path = target.path
        return asset
      }
      let clips = cues.map { $0.audioClip(using: assets[byText[$0.text]!]) }
      return Output(assets: assets, clips: clips)
    } catch {
      try? fm.removeItem(at: destination)
      throw error
    }
  }

  private static func synthesize<Payload: Encodable>(
    _ payload: Payload, total: Int?, voice: VoiceoverProfile?, resources: URL,
    support: URL, scratch: MediaScratch, report: Report
  ) async throws {
    let model = try Audio8Model(resources: resources)
    let folder = try await model.prepare(in: support.appendingPathComponent("Audio8Models")) {
      await report(.downloading($0))
    }
    try Task.checkCancellation()
    let request = try scratch.make(.json)
    let progress = try scratch.make(.log)
    try JSONEncoder().encode(payload).write(to: request.url, options: .atomic)
    let voiceFolder = voice?.folder(in: support).path ?? ""
    let fallback = AppLanguage.current == .english ? "en" : "zh"
    await report(total.map { .synthesizing(0, $0) } ?? .preparing)
    var previous = ""
    let status = try await run(interpreter(in: resources), arguments: [
      "-IB", resources.appendingPathComponent("voiceover.py").path,
      total == nil ? "instant" : "synthesize", folder.path, request.url.path,
      progress.url.path, voiceFolder, fallback
    ], scratch: scratch) {
      guard let value = try? String(contentsOf: progress.url, encoding: .ascii), value != previous
      else { return }
      let counts = value.split(separator: "/").compactMap { Int($0) }
      if let done = counts.first, let length = total ?? (counts.count == 2 ? counts[1] : nil), length > 0, (0...length).contains(done) {
        previous = value
        await report(.synthesizing(done, length))
      }
    }
    guard status == 0 else {
      throw EditError.message(total == nil
        ? L("无法朗读这段文字。请检查内容，或拆成较短的段落。")
        : L("无法合成这批字幕。请检查字幕文字，或分批生成。"))
    }
  }

  static func register(
    _ profile: VoiceoverProfile, recording: URL, resources: URL, support: URL,
    scratch: MediaScratch = .shared, report: Report
  ) async throws {
    let media = try inspect(recording)
    let rejection = L("请选择 0.5 至 30 秒的音频录音。")
    guard media.audio, !media.video, (fps / 2...30 * fps).contains(media.frames) else {
      throw EditError.message(rejection)
    }
    let pcm = try scratch.make(.wav)
    let converted = try await run(URL(fileURLWithPath: "/usr/bin/afconvert"), arguments: [
      "-f", "WAVE", "-d", "LEI16@44100", "-c", "1", recording.path, pcm.url.path
    ], scratch: scratch)
    guard converted == 0 else { throw EditError.message(rejection) }

    let model = try Audio8Model(resources: resources)
    let folder = try await model.prepare(in: support.appendingPathComponent("Audio8Models"), registration: true) {
      await report(.downloading($0))
    }
    let codes = try scratch.make(.npy)
    await report(.registering)
    let status = try await run(interpreter(in: resources), arguments: [
      "-IB", resources.appendingPathComponent("voiceover.py").path, "register",
      folder.path, pcm.url.path, codes.url.path
    ], scratch: scratch)
    guard status == 0, FileManager.default.fileExists(atPath: codes.url.path) else {
      throw EditError.message(L("无法建立自定义音色，请换一段清晰的人声录音。"))
    }

    let destination = profile.folder(in: support)
    let fm = FileManager.default
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    do {
      try fm.moveItem(at: codes.url, to: destination.appendingPathComponent("codes.npy"))
      let data = try JSONEncoder().encode(profile)
      try data.write(to: destination.appendingPathComponent("meta.json"), options: .atomic)
    } catch {
      try? fm.removeItem(at: destination)
      throw error
    }
  }

  private static func run(
    _ executable: URL, arguments: [String], scratch: MediaScratch,
    poll: () async -> Void = {}
  ) async throws -> Int32 {
    let log = try scratch.make(.log)
    try Data().write(to: log.url)
    let diagnostics = try FileHandle(forWritingTo: log.url)
    defer { try? diagnostics.close() }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = diagnostics
    process.qualityOfService = .utility

    try Task.checkCancellation()
    try process.run()
    defer {
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
    }
    while process.isRunning {
      try await Task.sleep(for: .milliseconds(250))
      await poll()
    }
    try Task.checkCancellation()
    if process.terminationStatus != 0, let details = try? String(contentsOf: log.url, encoding: .utf8) {
      NSLog("Audio8: %@", String(details.suffix(2000)))
    }
    return process.terminationStatus
  }
}
