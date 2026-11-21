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

struct CaptionTranslationPassage {
  let indices: Range<Int>
  let taggedSource: String?

  static func make(from lines: [SubtitleTranslationLine], source: [String]) -> [Self] {
    var passages: [Self] = []
    var start = 0
    while start < lines.count {
      var end = start + 1
      var characters = source[start].count
      while end < lines.count, end - start < 5,
        lines[end].start - (lines[end - 1].start + lines[end - 1].length) <= 36,
        characters + source[end].count <= 340
      {
        characters += source[end].count
        end += 1
      }
      let indices = start..<end
      let containsTag = source[indices].contains { marker.firstMatch(
        in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
      }
      let text = indices.count > 1 && !containsTag ? indices.enumerated().map { offset, index in
        "[\(offset + 101)] " + source[index].split(whereSeparator: \.isNewline).joined(separator: " ")
      }.joined(separator: "\n") : nil
      passages.append(Self(indices: indices, taggedSource: text))
      start = end
    }
    return passages
  }

  private static let marker = try! NSRegularExpression(pattern: #"[\[［〔【]\s*(10[1-5])\s*[\]］〕】]"#)

  func unpack(_ response: String) -> [String]? {
    let matches = Self.marker.matches(in: response, range: NSRange(response.startIndex..., in: response))
    guard matches.count == indices.count,
      let first = matches.first.flatMap({ Range($0.range, in: response) }),
      response[..<first.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    var results: [String] = []
    for (index, match) in matches.enumerated() {
      guard let mark = Range(match.range, in: response), let id = Range(match.range(at: 1), in: response),
        Int(response[id]) == index + 101 else { return nil }
      let end = index + 1 < matches.count
        ? Range(matches[index + 1].range, in: response)?.lowerBound ?? response.endIndex : response.endIndex
      let text = response[mark.upperBound..<end].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }
      results.append(text)
    }
    return results
  }

  /// The generic engine sometimes interprets corporate guidance as rules.
  /// Limit the correction to cues whose source uses the term in a financial context.
  static func refineEnglish(_ value: String, original: String, context: String) -> String {
    guard original.contains("指引"), !original.contains("指南"),
      ["季度", "财报", "營收", "营收", "业绩", "業績", "估值", "市场预期", "市場預期"]
        .contains(where: context.contains) else { return value }
    return value.replacingOccurrences(
      of: #"\bguidelines?\b"#, with: "guidance", options: [.regularExpression, .caseInsensitive])
  }
}
