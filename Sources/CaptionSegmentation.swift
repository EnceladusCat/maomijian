import Foundation
import NaturalLanguage

struct RecognizedSpeech {
  let start: Double, end: Double
  var text: String
}

enum CaptionSegmentation {
  private struct TimedCharacter {
    let value: Character
    let start: Double, end: Double
    var width: Double { value.isWhitespace ? 0.25 : value.isASCII ? 0.55 : 1 }
  }

  private struct Boundary {
    let position: Int, previous: Int
    let reward: Double
    let hard: Bool
  }

  private static let preferredWidth = 15.0
  private static let maximumWidth = 20.0
  private static let maximumSeconds = 5.5

  private static let stops: Set<Character> = ["。", "！", "？", "!", "?", ".", "…"]
  private static let softStops: Set<Character> = ["，", "、", "；", "：", ",", ";", ":"]
  private static let openers: Set<Character> = ["（", "(", "【", "[", "《", "「", "『", "“", "‘", "«"]
  private static let closers: Set<Character> = ["）", ")", "】", "]", "》", "」", "』", "”", "’", "»"]
  private static let clauseStarts = [
    "但是", "不过", "不过呢", "所以", "因此", "那么", "另一方面", "换句话说", "也就是说", "而是",
    "接下来", "先说", "再说", "最后", "总之", "同时", "另外", "以及", "甚至", "如果", "注意", "至于",
    "不過", "那麼", "換句話說", "也就是說", "接下來", "最後", "總之", "同時", "至於",
  ]
  private static let commonPhrases = [
    "什么时候", "什么地方", "怎么回事", "多少时间", "多少钱", "多长时间", "多大程度",
    "有多少", "有多大", "是不是", "能不能", "会不会", "有没有", "可不可以", "能否",
    "不一定", "至少", "不只是", "不仅仅", "主要是", "取决于", "由于", "否则", "也可以",
  ]
  private static let lastWordNeedsObject: Set<Character> = [
    "的", "地", "得", "把", "被", "将", "向", "从", "由", "和", "与", "是", "有", "能", "要", "会",
  ]
  private static let numbersAndUnits = try! NSRegularExpression(
    pattern: #"[0-9]+(?:[.,，][0-9]+)*(?:\s*(?:万亿|百万|亿|万)?(?:美元|人民币|港元|元|月|日|年|天|小时|秒|个|次|倍|%|％))?"#)

  static func captions(
    _ segments: [RecognizedSpeech], offset: Int, duration: Int,
    language: String, terms: [String] = []
  ) -> [Clip] {
    let glyphs = timeline(segments, duration: duration)
    guard !glyphs.isEmpty else { return [] }
    let text = String(glyphs.map(\.value))
    guard text.count == glyphs.count else { return [] }
    var widths = [0.0]
    for glyph in glyphs { widths.append(widths.last! + glyph.width) }
    let boundaries = boundaries(in: text, glyphs: glyphs, widths: widths, language: language, terms: terms)
    let ranges = cues(in: glyphs, boundaries: boundaries, widths: widths)
    var entries = [Clip]()
    for range in ranges {
      let first = max(entries.last.map { $0.end - offset } ?? 0, frame(glyphs[range.lowerBound].start, duration))
      let last = min(duration, max(first + 1, frame(glyphs[range.upperBound - 1].end, duration)))
      let text = String(glyphs[range].map(\.value))
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        .replacingOccurrences(of: #" +(?=[，。！？；：、,.!?;:）)】\]》」』])"#, with: "", options: .regularExpression)
      guard last > first, text.contains(where: { $0.isLetter || $0.isNumber || $0.isSymbol }) else { continue }
      var caption = Clip.annotation(.caption, at: first + offset)
      caption.length = last - first
      caption.text = text
      entries.append(caption)
    }
    return entries
  }

  private static func frame(_ seconds: Double, _ duration: Int) -> Int {
    Int(bound(seconds * Double(fps), 0, Double(duration)).rounded())
  }

  private static func timeline(_ segments: [RecognizedSpeech], duration: Int) -> [TimedCharacter] {
    var glyphs = [TimedCharacter]()
    let limit = Double(duration) / Double(fps)
    for piece in segments.sorted(by: { $0.start < $1.start })
      where piece.start.isFinite && piece.end.isFinite && piece.end > piece.start
        && piece.start >= 0 && piece.start < limit && !piece.text.isEmpty
    {
      let letters = Array(piece.text.precomposedStringWithCanonicalMapping)
      if let previous = glyphs.last, let next = letters.first,
        asciiWordCharacter(previous.value), asciiWordCharacter(next)
      {
        glyphs.append(TimedCharacter(value: " ", start: previous.end, end: piece.start))
      }
      let span = (min(limit, piece.end) - piece.start) / Double(letters.count)
      for (index, value) in letters.enumerated() {
        if value.isWhitespace && (glyphs.last?.value.isWhitespace ?? true) { continue }
        let timed = TimedCharacter(
          value: value.isWhitespace ? " " : value,
          start: piece.start + Double(index) * span, end: piece.start + Double(index + 1) * span)
        if let previous = glyphs.last, !timed.value.isASCII,
          let joined = joinedGrapheme(previous.value, timed.value)
        {
          glyphs[glyphs.count - 1] = TimedCharacter(value: joined, start: previous.start, end: timed.end)
        } else {
          glyphs.append(timed)
        }
      }
    }
    while glyphs.last?.value.isWhitespace == true { glyphs.removeLast() }
    return glyphs
  }

  private static func asciiWordCharacter(_ c: Character) -> Bool {
    c.isASCII && (c.isLetter || c.isNumber)
  }

  private static func joinedGrapheme(_ lhs: Character, _ rhs: Character) -> Character? {
    let pair = String(lhs) + String(rhs)
    return pair.count == 1 ? pair.first : nil
  }

  private static func boundaries(
    in text: String, glyphs: [TimedCharacter], widths: [Double], language: String, terms: [String]
  ) -> [Boundary] {
    let indexes = Array(text.indices) + [text.endIndex]
    let positions = Dictionary(uniqueKeysWithValues: indexes.enumerated().map { ($0.element, $0.offset) })
    let chinese = language.hasPrefix("zh") || language.hasPrefix("yue")
    let scriptWithoutSpaces = chinese || language.hasPrefix("ja") || language.hasPrefix("ko")
    var blocked = Set<Int>()
    var fallback = Set<Int>()
    func protect(_ word: Range<String.Index>, fromTokenizer: Bool = false) {
      guard let first = positions[word.lowerBound], let last = positions[word.upperBound], last > first + 1 else { return }
      let interior = (first + 1)..<last
      if fromTokenizer && scriptWithoutSpaces && widths[last] - widths[first] > maximumWidth {
        fallback.formUnion(interior)
      } else {
        blocked.formUnion(interior)
      }
    }
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = text
    switch language {
    case "zh-CN": tokenizer.setLanguage(.simplifiedChinese)
    case "zh-TW", "yue-HK": tokenizer.setLanguage(.traditionalChinese)
    case "en-US": tokenizer.setLanguage(.english)
    case "ja-JP": tokenizer.setLanguage(.japanese)
    case "ko-KR": tokenizer.setLanguage(.korean)
    default: break
    }
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
      protect(range, fromTokenizer: true)
      return true
    }
    let phrases = chinese ? commonPhrases + clauseStarts + terms : terms
    for term in phrases where !term.isEmpty {
      var search = text.startIndex..<text.endIndex
      while let match = text.range(of: term, options: [.caseInsensitive, .literal], range: search) {
        protect(match)
        search = match.upperBound..<text.endIndex
      }
    }
    for match in numbersAndUnits.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) {
      if let range = Range(match.range, in: text) { protect(range) }
    }
    var result = [Boundary(position: 0, previous: 0, reward: 0, hard: true)]
    var previous = 0
    for i in glyphs.indices.dropFirst() {
      if !glyphs[i - 1].value.isWhitespace { previous = i - 1 }
      let left = glyphs[previous].value
      let right = glyphs[i].value
      if blocked.contains(i) || right.isWhitespace || stops.contains(right) || softStops.contains(right)
        || closers.contains(right) || openers.contains(left) { continue }
      if i == previous + 1, chinese, left == right, !right.isASCII, right.isLetter,
        glyphs[i].start - glyphs[previous].end < 0.18
      { continue }
      var punctuation = previous
      while punctuation > 0, closers.contains(glyphs[punctuation].value) { punctuation -= 1 }
      let mark = glyphs[punctuation].value
      let internalPeriod = mark == "." && punctuation + 1 == i && punctuation > 0
        && asciiWordCharacter(glyphs[punctuation - 1].value) && asciiWordCharacter(right)
      let sentence = stops.contains(mark) && !internalPeriod
      let pause = max(0, glyphs[i].start - glyphs[previous].end)
      let nextClause = chinese && clauseStarts.contains { text[indexes[i]...].hasPrefix($0) }
      let reward = (softStops.contains(mark) ? 3.4 : 0)
        + min(pause * 9, 4.5) + (nextClause ? 3.1 : 0)
        - (chinese && lastWordNeedsObject.contains(left) ? 3.0 : 0)
        - (fallback.contains(i) ? 7.0 : 0)
      result.append(Boundary(position: i, previous: previous, reward: reward, hard: sentence || pause >= 1.15))
    }
    result.append(Boundary(position: glyphs.count, previous: glyphs.count - 1, reward: 0, hard: true))
    return result
  }

  private static func cues(
    in glyphs: [TimedCharacter], boundaries: [Boundary], widths: [Double]
  ) -> [Range<Int>] {
    var cost = [Double](repeating: .infinity, count: boundaries.count)
    var prev = [Int](repeating: 0, count: boundaries.count)
    cost[0] = 0
    var sentenceStart = 0
    for i in boundaries.indices.dropFirst() {
      let end = boundaries[i]
      for j in stride(from: i - 1, through: sentenceStart, by: -1) {
        let start = boundaries[j].position
        let units = widths[end.previous + 1] - widths[start]
        let seconds = glyphs[end.previous].end - glyphs[start].start
        // Keeping an indivisible word or protected term intact can exceed the limit.
        if j < i - 1 && (units > maximumWidth + 1e-8 || seconds > maximumSeconds) { break }
        let widthPenalty = pow((units - preferredWidth) / 7, 2)
        let timePenalty = pow(max(0, seconds - 3.6) * 1.1, 2)
        let short = units < 6 || seconds < 0.8 ? 4.0 : 0
        let total = cost[j] + widthPenalty + timePenalty + short + 2.5 - end.reward
        if total < cost[i] {
          cost[i] = total
          prev[i] = j
        }
      }
      if end.hard { sentenceStart = i }
    }
    var ranges = [Range<Int>]()
    var i = boundaries.count - 1
    while i > 0 {
      let j = prev[i]
      ranges.append(boundaries[j].position..<boundaries[i].previous + 1)
      i = j
    }
    return ranges.reversed()
  }
}
