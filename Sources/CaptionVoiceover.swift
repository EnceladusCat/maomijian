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

enum VoiceoverFormat: String {
  case m4a, wav

  var scratchFormat: MediaScratch.Format { self == .m4a ? .audio : .wav }
}

struct VoiceoverCue: Equatable {
  let id: UUID
  let start: Int
  let length: Int
  let text: String

  init(_ clip: Clip, source: VoiceoverText, glossary: CaptionGlossary = .empty) {
    id = clip.id
    start = clip.start
    length = clip.length
    text = glossary.read(source.text(in: clip))
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
    case preparing, downloading(Double), registering, synthesizing(Int, Int), exporting(VoiceoverFormat)
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

  struct InstantOutput {
    let file: MediaScratch.File
    let text: String
    let voiceID: UUID?
    let frames: Int
  }

  typealias Report = (Stage) async -> Void
  @Published var instantText = ""
  @Published private(set) var instant: InstantOutput?
  let audition = SoundAudition()
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

  func generateText(voice: VoiceoverProfile?, glossary: CaptionGlossary = .empty) {
    let text = glossary.read(instantText.trimmingCharacters(in: .whitespacesAndNewlines))
    guard job == nil, !text.isEmpty, let resources = Self.resources else { return }
    audition.stop()
    let support = Self.support
    perform(discard: { _ in }, work: { report in
      try await Self.renderText(text, voice: voice, resources: resources, support: support, report: report)
    }, accept: { [weak self] output in
      self?.instant = output
      return ""
    })
  }

  func export(
    _ instant: InstantOutput, format: VoiceoverFormat, to destination: URL,
    validate: @escaping () throws -> Void
  ) {
    guard job == nil else { return }
    audition.stop()
    let encoder = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg")
    perform(stage: .exporting(format), discard: { _ in }, work: { _ in
      try await Self.stageExport(instant.file, format: format, to: destination, encoder: encoder)
    }, accept: { file in
      do {
        try validate()
        try ExportJob.commit(file.url, destination)
        return L("已导出 ") + destination.lastPathComponent
      } catch { return error.localizedDescription }
    })
  }

  func reset() {
    cancel()
    audition.stop()
    instant = nil
    notice = ""
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
    stage initialStage: Stage = .preparing,
    discard: @escaping (T) -> Void, work: @escaping (Report) async throws -> T,
    accept: @escaping (T) -> String
  ) {
    guard job == nil else { return }
    stage = initialStage
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
    _ text: String, voice: VoiceoverProfile?, resources: URL, support: URL,
    scratch: MediaScratch = .shared, report: Report
  ) async throws -> InstantOutput {
    let file = try scratch.make(.wav)
    let request = Request(text: text, path: file.url.path)
    try await synthesize(request, total: nil, voice: voice, resources: resources, support: support,
                         scratch: scratch, report: report)
    let audio = try inspect(file.url)
    guard audio.audio, !audio.video else { throw CocoaError(.fileReadCorruptFile) }
    return InstantOutput(file: file, text: text, voiceID: voice?.id, frames: audio.frames)
  }

  static func stageExport(
    _ source: MediaScratch.File, format: VoiceoverFormat, to destination: URL, encoder: URL,
    scratch: MediaScratch = .shared
  ) async throws -> MediaScratch.File {
    try Task.checkCancellation()
    let staged = try scratch.make(format.scratchFormat, beside: destination.deletingLastPathComponent())
    switch format {
    case .wav:
      try FileManager.default.copyItem(at: source.url, to: staged.url)
    case .m4a:
      guard FileManager.default.isExecutableFile(atPath: encoder.path) else {
        throw EditError.message(L("找不到随应用提供的 M4A 编码器。"))
      }
      let status = try await LocalInference.run(encoder, arguments: [
        "-hide_banner", "-loglevel", "error", "-nostdin", "-xerror", "-i", source.url.path,
        "-map", "0:a:0", "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart",
        "-f", "ipod", staged.url.path
      ], scratch: scratch)
      guard status == 0, FileManager.default.fileExists(atPath: staged.url.path) else {
        throw EditError.message(L("无法编码 M4A 音频。"))
      }
    }
    try Task.checkCancellation()
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
    let decoderGraph = try scratch.make(.onnx)
    let decoderWeights = try scratch.make(.weights)
    defer { withExtendedLifetime((request, progress, decoderGraph, decoderWeights)) {} }
    try JSONEncoder().encode(payload).write(to: request.url, options: .atomic)
    let voiceFolder = voice?.folder(in: support).path ?? ""
    let fallback = AppLanguage.current == .english ? "en" : "zh"
    await report(total.map { .synthesizing(0, $0) } ?? .preparing)
    var previous = ""
    let status = try await LocalInference.run(interpreter(in: resources), arguments: [
      "-IB", resources.appendingPathComponent("voiceover.py").path,
      total == nil ? "instant" : "synthesize", folder.path, request.url.path,
      progress.url.path, voiceFolder, fallback, decoderGraph.url.path, decoderWeights.url.path
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
    let converted = try await LocalInference.run(URL(fileURLWithPath: "/usr/bin/afconvert"), arguments: [
      "-f", "WAVE", "-d", "LEI16@44100", "-c", "1", recording.path, pcm.url.path
    ], scratch: scratch)
    guard converted == 0 else { throw EditError.message(rejection) }

    let model = try Audio8Model(resources: resources)
    let folder = try await model.prepare(in: support.appendingPathComponent("Audio8Models"), registration: true) {
      await report(.downloading($0))
    }
    let codes = try scratch.make(.npy)
    await report(.registering)
    let status = try await LocalInference.run(interpreter(in: resources), arguments: [
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
}
