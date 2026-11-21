import AVFoundation
import Combine
import Foundation
#if compiler(>=6.2) && canImport(Speech)
  import Speech
#endif

enum CaptionLanguage: String, CaseIterable {
  case mandarin = "zh-CN"
  case traditional = "zh-TW"
  case english = "en-US"
  case cantonese = "yue-HK"
  case japanese = "ja-JP"
  case korean = "ko-KR"

  var label: String {
    switch self {
    case .mandarin: return L("普通话（简体）")
    case .traditional: return L("普通话（繁体）")
    case .english: return L("英语")
    case .cantonese: return L("粤语")
    case .japanese: return L("日语")
    case .korean: return L("韩语")
    }
  }
}

final class CaptionProgress: @unchecked Sendable {
  private let lock = NSLock()
  private let startedAt: TimeInterval
  private var fraction = 0.0
  private var elapsed = 0.0

  init(startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    self.startedAt = startedAt
  }

  func update(_ value: Double, at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    guard value.isFinite else { return }
    let next = min(1, value)
    lock.lock()
    defer { lock.unlock() }
    guard next > fraction else { return }
    fraction = next
    elapsed = max(0, uptime - startedAt)
  }

  func snapshot() -> (fraction: Double, remainingSeconds: Int?) {
    lock.lock()
    defer { lock.unlock() }
    guard fraction >= 0.02, elapsed >= 0.5 else { return (fraction, nil) }
    let estimate = min(86_400, (elapsed / fraction) * (1 - fraction))
    guard estimate.isFinite else { return (fraction, nil) }
    return (fraction, Int(estimate.rounded(.up)))
  }
}

final class AutomaticCaptions: ObservableObject {
  enum Stage {
    case preparingAudio(CaptionProgress), preparingModel, recognizing(CaptionProgress), arranging

    var label: String {
      switch self {
      case .preparingAudio: return L("正在准备音频")
      case .preparingModel: return L("正在准备语言模型")
      case .recognizing: return L("正在识别字幕")
      case .arranging: return L("正在整理字幕")
      }
    }
  }

  @Published private(set) var stage: Stage?
  private var id: UUID?
  private var task: Task<[Clip], Error>?
  private var audioExport: ExportJob?

  static var available: Bool {
    #if compiler(>=6.2) && canImport(Speech)
      if #available(macOS 26, *) { return true }
    #endif
    return false
  }

  func start(
    project: Project, offset: Int, language: CaptionLanguage, terms: [String],
    completion: @escaping (Result<[Clip], Error>) -> Void
  ) {
    guard stage == nil else { return }
    #if compiler(>=6.2) && canImport(Speech)
      if #available(macOS 26, *) {
        let id = UUID()
        let export = ExportJob()
        self.id = id
        audioExport = export
        let audioProgress = CaptionProgress()
        stage = .preparingAudio(audioProgress)
        let work = Task.detached(priority: .utility) { [weak self] in
          try Task.checkCancellation()
          let audio = try MediaScratch.shared.make(.audio)
          defer { withExtendedLifetime(audio) {} }
          try export.runAudio(project, to: audio.url) { audioProgress.update($0) }
          try Task.checkCancellation()
          await MainActor.run { [weak self] in self?.report(.preparingModel, id: id) }
          let speech = try await Self.transcribe(audio.url, language: language, terms: terms) { progress in
            await MainActor.run { [weak self] in self?.report(.recognizing(progress), id: id) }
          }
          try Task.checkCancellation()
          await MainActor.run { [weak self] in self?.report(.arranging, id: id) }
          return CaptionSegmentation.captions(
            speech, offset: offset, duration: project.duration, language: language.rawValue, terms: terms)
        }
        task = work
        Task { @MainActor [weak self] in
          let result = await work.result
          guard let self, self.id == id else { return }
          self.stage = nil
          self.id = nil
          self.task = nil
          self.audioExport = nil
          completion(result)
        }
        return
      }
    #endif
    completion(.failure(EditError.message(L("自动字幕需要 macOS 26 或更新版本。"))))
  }

  private func report(_ next: Stage, id: UUID) {
    if self.id == id { stage = next }
  }

  func cancel() {
    id = nil
    task?.cancel()
    audioExport?.cancel()
    task = nil
    audioExport = nil
    stage = nil
  }
}

#if compiler(>=6.2) && canImport(Speech)
  @available(macOS 26, *)
  extension AutomaticCaptions {
    private static func transcribe(
      _ audio: URL, language: CaptionLanguage, terms: [String],
      ready: @escaping (CaptionProgress) async -> Void
    ) async throws -> [RecognizedSpeech] {
      let requested = Locale(identifier: language.rawValue)
      if SpeechTranscriber.isAvailable,
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested)
      {
        let recognizer = SpeechTranscriber(locale: locale, transcriptionOptions: [],
          reportingOptions: [], attributeOptions: [.audioTimeRange])
        return try await recognize(audio, module: recognizer, results: recognizer.results, terms: terms, ready: ready) {
          $0.isFinal ? words($0.text, fallback: $0.range) : []
        }
      }
      if let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) {
        let recognizer = DictationTranscriber(locale: locale, preset: .timeIndexedLongDictation)
        return try await recognize(audio, module: recognizer, results: recognizer.results, terms: terms, ready: ready) {
          $0.isFinal ? words($0.text, fallback: $0.range) : []
        }
      }
      throw EditError.message(L("这台 Mac 的本地语音模型不支持「\(language.label)」。"))
    }

    private static func words(_ text: AttributedString, fallback: CMTimeRange) -> [RecognizedSpeech] {
      var spans = [RecognizedSpeech]()
      var leading = ""
      for run in text.runs {
        let token = String(text[run.range].characters)
        if let range = run.audioTimeRange, range.start.isNumeric, range.end.isNumeric, range.duration > .zero {
          spans.append(RecognizedSpeech(start: range.start.seconds, end: range.end.seconds, text: leading + token))
          leading = ""
        } else if let last = spans.indices.last {
          spans[last].text += token
        } else {
          leading += token
        }
      }
      return spans.isEmpty
        ? [RecognizedSpeech(start: fallback.start.seconds, end: fallback.end.seconds, text: String(text.characters))]
        : spans
    }

    private static func recognize<Results: AsyncSequence & Sendable>(
      _ audio: URL, module: any SpeechModule, results: Results, terms: [String],
      ready: @escaping (CaptionProgress) async -> Void, extract: @escaping (Results.Element) -> [RecognizedSpeech]
    ) async throws -> [RecognizedSpeech] {
      let modules = [module]
      if let install = try await AssetInventory.assetInstallationRequest(supporting: modules) {
        try await install.downloadAndInstall()
      }
      try Task.checkCancellation()
      let context = AnalysisContext()
      context.contextualStrings = [.general: terms]
      let analyzer = SpeechAnalyzer(modules: modules)
      try await analyzer.setContext(context)
      let file = try AVAudioFile(forReading: audio)
      let gather = Task<[RecognizedSpeech], Error> {
        var spans = [RecognizedSpeech]()
        for try await result in results {
          try Task.checkCancellation()
          spans += extract(result)
        }
        return spans
      }
      let progress = CaptionProgress()
      let audioDuration = Double(file.length) / file.processingFormat.sampleRate
      if audioDuration.isFinite && audioDuration > 0 {
        await analyzer.setVolatileRangeChangedHandler { range, changedStart, _ in
          if changedStart { progress.update(range.start.seconds / audioDuration) }
        }
      }
      await ready(progress)
      return try await withTaskCancellationHandler {
        do {
          if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
          } else {
            await analyzer.cancelAndFinishNow()
          }
          return try await gather.value
        } catch {
          await analyzer.cancelAndFinishNow()
          gather.cancel()
          throw error
        }
      } onCancel: {
        gather.cancel()
        Task { await analyzer.cancelAndFinishNow() }
      }
    }
  }
#endif
