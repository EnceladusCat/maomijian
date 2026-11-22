import Foundation

enum CaptionIssue: String, CaseIterable, Hashable {
  case blank = "正文为空"
  case long = "字幕过长"
  case fast = "阅读时间偏短"
  case breakPoint = "断句可疑"
  case missingTranslation = "缺少译文"
  case repeatLine = "相邻重复"
  case filler = "疑似口头语"

  var title: String { LKey(rawValue) }
}

struct TranscriptRow: Identifiable, Equatable {
  enum ID: Hashable { case cue(UUID), gap(Int, Int) }
  let caption: Clip?
  let span: Range<Int>
  let issues: [CaptionIssue]
  var id: ID { caption.map { .cue($0.id) } ?? .gap(span.lowerBound, span.upperBound) }

  static func rows(_ captions: [Clip]) -> [Self] {
    let bilingual = captions.contains { !$0.captionTranslation.orEmpty.isEmpty }
    var result = [Self]()
    var coveredUntil: Int?
    var previous: Clip?
    for cue in captions.sorted(by: { $0.start < $1.start }) {
      if let end = coveredUntil, cue.start - end >= fps {
        result.append(Self(caption: nil, span: end..<cue.start, issues: []))
      }
      let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
      let sizes = [text, cue.captionTranslation.orEmpty].map { line in
        line.reduce(0.0) { $0 + ($1.isWhitespace ? 0 : $1.isASCII ? 0.55 : 1) }
      }
      let width = sizes.max() ?? 0
      var issues = [CaptionIssue]()
      if text.isEmpty { issues.append(.blank) }
      if width > 20 { issues.append(.long) }
      if cue.length * 2 < fps { issues.append(.fast) }
      if text.first.map({ "，。、！？；：）】」』”’".contains($0) }) == true
        || text.last.map({ "（【「『“‘".contains($0) }) == true
        || (text.first?.isLowercase == true && previous.map {
          cue.start >= $0.end && cue.start - $0.end <= fps / 4
            && $0.text.last.map { !".!?。！？".contains($0) } == true
        } == true)
      { issues.append(.breakPoint) }
      if bilingual && cue.captionTranslation.orEmpty.isEmpty { issues.append(.missingTranslation) }
      let spoken = plain(text)
      if !spoken.isEmpty, let previous, cue.start >= previous.end, cue.start - previous.end < fps,
        spoken == plain(previous.text) { issues.append(.repeatLine) }
      if ["嗯", "呃", "额", "啊", "呃呃", "嗯嗯", "um", "uh", "erm", "hmm"].contains(spoken) {
        issues.append(.filler)
      }
      result.append(Self(caption: cue, span: cue.start..<cue.end, issues: issues))
      coveredUntil = max(coveredUntil ?? 0, cue.end)
      previous = cue
    }
    return result
  }

  private static func plain(_ text: String) -> String {
    String(text.lowercased().filter { $0.isLetter || $0.isNumber })
  }
}

extension Project {
  mutating func mergeCaptions(_ firstID: UUID, _ secondID: UUID, body: String? = nil, translation: String? = nil) {
    guard let first = clips.firstIndex(where: { $0.id == firstID && $0.kind == .caption }),
      let second = clips.firstIndex(where: { $0.id == secondID && $0.kind == .caption }),
      clips[first].end <= clips[second].start else { return }
    let next = clips[second]
    clips[first].text = Self.joinCaptionText(body ?? clips[first].text, next.text)
    let mergedTranslation = Self.joinCaptionText(translation ?? clips[first].captionTranslation ?? "",
                                                  next.captionTranslation ?? "")
    clips[first].captionTranslation = mergedTranslation.isEmpty ? nil : mergedTranslation
    clips[first].length = next.end - clips[first].start
    clips.remove(at: second)
    clearSingletonGroups()
  }

  private static func joinCaptionText(_ left: String, _ right: String) -> String {
    let left = left.trimmingCharacters(in: .whitespacesAndNewlines)
    let right = right.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let tail = left.last, let head = right.first else { return left + right }
    let separator = tail.isASCII && head.isASCII && (head.isLetter || head.isNumber || head == "(")
      && tail != "(" ? " " : ""
    return left + separator + right
  }
}

enum TranscriptEdit {
  case cut, keep

  func intervals(_ selection: [Range<Int>], duration: Int) -> [Range<Int>] {
    var merged: [Range<Int>] = []
    for span in selection.sorted(by: { $0.lowerBound < $1.lowerBound }) {
      let lower = max(0, span.lowerBound), upper = min(duration, span.upperBound)
      guard lower < upper else { continue }
      if let last = merged.last, lower <= last.upperBound {
        merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, upper)
      } else {
        merged.append(lower..<upper)
      }
    }
    guard self == .keep, !merged.isEmpty else { return merged }
    var cursor = 0
    var remove = [Range<Int>]()
    for span in merged {
      if cursor < span.lowerBound { remove.append(cursor..<span.lowerBound) }
      cursor = span.upperBound
    }
    if cursor < duration { remove.append(cursor..<duration) }
    return remove
  }
}

struct CaptionGlossary {
  static let empty = Self(nil)
  private let entries: [(source: String, target: String, pronunciation: Bool, expression: NSRegularExpression)]

  init(_ text: String?) {
    entries = (text ?? "").split(whereSeparator: \.isNewline).compactMap { line in
      let separator = line.range(of: "→") ?? line.range(of: "=>") ?? line.range(of: "=")
      guard let separator else { return nil }
      let source = line[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
      let target = line[separator.upperBound...].trimmingCharacters(in: .whitespaces)
      guard !source.isEmpty, !target.isEmpty else { return nil }
      let word = "[A-Za-z0-9_]"
      let beginsWithWord = source.first.map(Self.wordCharacter) == true
      let endsWithWord = source.last.map(Self.wordCharacter) == true
      let pattern = (beginsWithWord ? "(?<!\(word))" : "") + NSRegularExpression.escapedPattern(for: source)
        + (endsWithWord ? "(?!\(word))" : "")
      guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
      return (source, target, line[separator] == "=", regex)
    }.sorted { $0.source.count > $1.source.count }
  }

  var recognitionTerms: [String] { entries.map { $0.pronunciation ? $0.source : $0.target } }

  func correct(_ text: String) -> String { replace(text, pronunciation: false) }
  func read(_ text: String) -> String { replace(correct(text), pronunciation: true) }

  private func replace(_ text: String, pronunciation: Bool) -> String {
    entries.reduce(text) { value, entry in
      guard entry.pronunciation == pronunciation else { return value }
      return entry.expression.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value),
        withTemplate: NSRegularExpression.escapedTemplate(for: entry.target))
    }
  }

  private static func wordCharacter(_ character: Character) -> Bool {
    character.isASCII && (character.isLetter || character.isNumber || character == "_")
  }
}

private extension Optional where Wrapped == String {
  var orEmpty: String { self?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
}
