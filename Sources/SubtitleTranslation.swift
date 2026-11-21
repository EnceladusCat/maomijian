import Foundation

extension CaptionLanguage {
  var translationCode: String {
    switch self {
    case .mandarin: return "zh-Hans"
    case .traditional: return "zh-Hant"
    case .cantonese: return "yue"
    case .english: return "en"
    case .japanese: return "ja"
    case .korean: return "ko"
    }
  }

  var translationLabel: String {
    switch self {
    case .mandarin: return L("简体中文")
    case .traditional: return L("繁体中文")
    default: return label
    }
  }
}

struct SubtitleTranslationPair: Hashable {
  let source: CaptionLanguage
  let target: CaptionLanguage

  var isChineseScriptConversion: Bool {
    (source == .mandarin && target == .traditional) || (source == .traditional && target == .mandarin)
  }
}

enum CaptionTranslationMode: CaseIterable {
  case bilingual, replace

  var title: String {
    switch self {
    case .bilingual: return L("双语字幕")
    case .replace: return L("仅译文")
    }
  }

  func apply(_ translations: [UUID: String], to project: inout Project) {
    for i in project.clips.indices where project.clips[i].kind == .caption {
      guard let translation = translations[project.clips[i].id] else { continue }
      switch self {
      case .bilingual: project.clips[i].captionTranslation = translation
      case .replace:
        project.clips[i].text = translation
        project.clips[i].captionTranslation = nil
      }
    }
  }
}

struct SubtitleTranslationLine: Equatable {
  let id: UUID
  let start: Int
  let length: Int
  let text: String
  let translation: String?

  init(_ clip: Clip) {
    id = clip.id
    start = clip.start
    length = clip.length
    text = clip.text
    translation = clip.captionTranslation
  }

  static func snapshot(in project: Project) -> [Self] {
    project.clips.filter { $0.kind == .caption && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .map(Self.init).sorted { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }
  }

  static func replacements(for lines: [Self], translated: [String]) throws -> [UUID: String] {
    guard lines.count == translated.count,
      translated.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
      throw EditError.message(L("翻译结果不完整，请重试。"))
    }
    return Dictionary(uniqueKeysWithValues: zip(lines.map(\.id), translated))
  }
}

enum SubtitleTranslator {
  static func convertScript(_ lines: [String], pair: SubtitleTranslationPair) throws -> [String] {
    try lines.map { text in
      guard let converted = text.applyingTransform(
        StringTransform("Hans-Hant"), reverse: pair.target == .mandarin) else {
        throw EditError.message(L("简繁转换失败，请重试。"))
      }
      return converted
    }
  }

}
