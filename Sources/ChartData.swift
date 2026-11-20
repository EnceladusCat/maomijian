import Foundation

enum ChartKind: String, Codable, CaseIterable {
  case pie, bar, line, scatter

  var title: String {
    switch self {
    case .pie: return L("饼图")
    case .bar: return L("柱状图")
    case .line: return L("折线图")
    case .scatter: return L("散点图")
    }
  }
  var icon: String {
    switch self {
    case .pie: return "chart.pie"
    case .bar: return "chart.bar.xaxis"
    case .line: return "chart.xyaxis.line"
    case .scatter: return "chart.dots.scatter"
    }
  }
}

enum ChartTheme: String, Codable, CaseIterable {
  case dark, light, transparent

  var title: String {
    switch self {
    case .dark: return L("深色")
    case .light: return L("浅色")
    case .transparent: return L("透明")
    }
  }
}

enum ChartColorMode: String, Codable, CaseIterable {
  case automatic, single, category, rank, magnitude, sign

  var title: String {
    switch self {
    case .automatic: return L("自动配色")
    case .single: return L("统一颜色")
    case .category: return L("分类配色")
    case .rank: return L("按排名")
    case .magnitude: return L("按绝对值")
    case .sign: return L("按正负值")
    }
  }
  var isGradient: Bool { self == .rank || self == .magnitude }
}

struct ChartAppearance: Codable, Equatable {
  var theme = ChartTheme.dark
  var backgroundOpacity = 1.0
  var font = ""
  var fontScale = 1.0
  var textColor: String?
  var showsTitle = true
  var showsLabels = true
  var showsValues: Bool?
  var showsGrid = true
  var colorMode = ChartColorMode.automatic
  var lowColor = "#6C57DB"
  var markSize = 1.0
  var pieHole = 0.0
  var areaFill: Bool?

  var valid: Bool {
    (0...1).contains(backgroundOpacity) && (0.6...1.5).contains(fontScale)
      && (0.35...2).contains(markSize) && (0...0.72).contains(pieHole)
  }
  func displaysValues(_ kind: ChartKind) -> Bool { showsValues ?? (kind == .pie) }
  func paletteMode(_ kind: ChartKind) -> ChartColorMode {
    colorMode == .automatic ? (kind == .pie ? .category : .single) : colorMode
  }
}

struct ChartPoint: Codable, Equatable {
  var label: String
  var x: Double? = nil
  var y: Double
}

struct ChartMarker: Codable, Equatable {
  var row: Int
  var title = ""
}

struct ChartSpec: Codable, Equatable {
  var kind: ChartKind
  var title: String
  var xTitle = ""
  var yTitle = ""
  var points: [ChartPoint]
  var entryFrames = 24
  var marker: ChartMarker?

  var valid: Bool {
    !points.isEmpty && (0...maxFrames).contains(entryFrames)
      && (marker.map { kind != .pie && points.indices.contains($0.row) } ?? true)
      && points.allSatisfy {
      $0.y.isFinite && $0.x?.isFinite != false
        && (kind != .pie || $0.y > 0) && (kind != .scatter || $0.x != nil)
    }
  }

  func progress(at frame: Int, in clip: Clip) -> Double {
    let duration = min(entryFrames, clip.length - 1)
    guard duration > 0 else { return 1 }
    let t = bound(Double(frame - clip.start) / Double(duration), 0, 1)
    return t * t * (3 - 2 * t)
  }

  var editableCSV: String {
    // An empty pair of headings is part of the editable format.
    return Self.quotedCell(xTitle) + "," + Self.quotedCell(yTitle) + "\n" + editableRows
  }

  var editableRows: String {
    points.map { point in
      if kind == .scatter {
        return "\(point.x ?? 0),\(point.y),\(Self.quotedCell(point.label))"
      }
      return Self.quotedCell(point.label) + "," + String(point.y)
    }.joined(separator: "\n")
  }

  private static func quotedCell(_ string: String) -> String {
    "\"" + string.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  func replacingData(from text: String, header: Bool = true) throws -> Self {
    let table = try ChartCSV(name: "", text: text, preservesHeader: header)
    let rows = table.rows.dropFirst(header ? 1 : 0)
    guard !rows.isEmpty else { throw EditError.message(L("没有可绘制的数据")) }
    let scatter = kind == .scatter
    let maxColumns = scatter ? 3 : 2
    var next = self
    next.points = try rows.enumerated().map { offset, row in
      let number = 1 + offset
      guard (2...maxColumns).contains(row.count) else {
        throw EditError.message(L("数据第 \(number) 行的列数有误。含分隔符的标签请用双引号括起。"))
      }
      guard let value = ChartCSV.number(row[1]) else {
        throw EditError.message(L("数据第 \(number) 行的数值无效。"))
      }
      if kind == .pie && value <= 0 {
        throw EditError.message(L("数据第 \(number) 行的饼图数值必须大于零。"))
      }
      if scatter {
        guard let x = ChartCSV.number(row[0]) else {
          throw EditError.message(L("数据第 \(number) 行的 X 值无效。"))
        }
        let label = row.count == 3 ? row[2] : row[0].trimmingCharacters(in: .whitespacesAndNewlines)
        return ChartPoint(label: label, x: x, y: value)
      }
      return ChartPoint(label: row[0], y: value)
    }
    if header {
      let titles = table.rows[0]
      next.xTitle = titles.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      next.yTitle = titles.count > 1 ? titles[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }
    return updatingData(with: next)
  }

  func updatingData(with draft: Self) -> Self {
    var next = draft
    next.entryFrames = entryFrames
    next.marker = matchingMarker(in: next.points, kind: next.kind)
    return next
  }

  private func matchingMarker(in updated: [ChartPoint], kind: ChartKind) -> ChartMarker? {
    guard var marker, kind != .pie, points.indices.contains(marker.row) else { return nil }
    if points == updated { return marker }
    let point = points[marker.row]
    func matched(_ samePoint: (ChartPoint) -> Bool) -> Int? {
      guard !points.dropFirst(marker.row + 1).contains(where: samePoint),
        !points.prefix(marker.row).contains(where: samePoint),
        let index = updated.firstIndex(where: samePoint),
        !updated.dropFirst(index + 1).contains(where: samePoint)
      else { return nil }
      return index
    }
    if let index = matched({ $0 == point }) {
      marker.row = index
    } else if !point.label.isEmpty, let index = matched({ $0.label == point.label }) {
      marker.row = index
    } else if let x = point.x, kind == .scatter, let index = matched({ $0.x == x }) {
      marker.row = index
    } else { return nil }
    return marker
  }
}

struct ChartCSV {
  let name: String
  let rows: [[String]]
  let columnCount: Int

  static func load(_ url: URL) throws -> Self {
    let data = try Data(contentsOf: url)
    let value: String?
    if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) {
      value = String(data: data, encoding: .utf16)
    } else {
      value = String(data: data, encoding: .utf8)
    }
    guard let value else { throw EditError.message(L("无法读取 CSV 编码。请保存为 UTF-8 或带 BOM 的 UTF-16。")) }
    return try Self(name: url.lastPathComponent, text: value)
  }

  init(name: String, text: String, preservesHeader: Bool = false) throws {
    self.name = name
    let input = text.first == "\u{feff}" ? text.dropFirst() : text[...]
    let separators: [Character] = [",", ";", "\t"]
    var counts = [Character: Int]()
    var quoted = false
    for ch in input {
      if ch == "\"" { quoted.toggle() }
      if quoted { continue }
      if ch.isNewline && !counts.isEmpty { break }
      if separators.contains(ch) { counts[ch, default: 0] += 1 }
    }
    let separator = separators.max { counts[$0, default: 0] < counts[$1, default: 0] } ?? ","
    var records = [[String]]()
    var record = [String](), field = ""
    var closedQuote = false
    quoted = false
    func finishField() {
      record.append(field)
      field = ""
      closedQuote = false
    }
    func finishRow() {
      finishField()
      if (preservesHeader && records.isEmpty && record.count > 1)
        || record.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
      {
        records.append(record)
      }
      record = []
    }
    for ch in input {
      if quoted {
        if ch == "\"" {
          quoted = false
          closedQuote = true
        } else { field.append(ch) }
      } else if ch == separator {
        finishField()
      } else if ch.isNewline {
        finishRow()
      } else if ch == "\"" {
        if closedQuote { field.append(ch) }
        else if field.trimmingCharacters(in: .whitespaces).isEmpty { field = "" }
        else { throw EditError.message(L("CSV 引号格式有误。")) }
        quoted = true
        closedQuote = false
      } else if closedQuote {
        if !ch.isWhitespace { throw EditError.message(L("CSV 引号格式有误。")) }
      } else {
        field.append(ch)
      }
    }
    guard !quoted else { throw EditError.message(L("CSV 引号格式有误。")) }
    finishRow()
    guard !records.isEmpty else { throw EditError.message(L("CSV 没有可读取的数据。")) }
    rows = records
    columnCount = records.map(\.count).max() ?? 0
  }

  func columns(header: Bool) -> [String] {
    (0..<columnCount).map { index in
      let title = header ? cell(rows[0], index) : ""
      return title.isEmpty ? L("第 \(index + 1) 列") : title
    }
  }

  func points(for kind: ChartKind, header: Bool, x: Int, y: Int) -> (points: [ChartPoint], skipped: Int) {
    let body = rows.dropFirst(header ? 1 : 0)
    let points = body.enumerated().compactMap { index, row -> ChartPoint? in
      guard let value = Self.number(cell(row, y)), kind != .pie || value > 0 else { return nil }
      let label = cell(row, x)
      let number = kind == .scatter ? Self.number(label) : nil
      guard kind != .scatter || number != nil else { return nil }
      return ChartPoint(label: label.isEmpty ? String(index + 1) : label, x: number, y: value)
    }
    return (points, body.count - points.count)
  }

  private func cell(_ row: [String], _ index: Int) -> String {
    guard row.indices.contains(index) else { return "" }
    return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
  }

  fileprivate static func number(_ string: String) -> Double? {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    let percent = trimmed.hasSuffix("%")
    let value = percent ? trimmed.dropLast().trimmingCharacters(in: .whitespaces) : trimmed
    guard let number = Double(value.replacingOccurrences(of: "−", with: "-")), number.isFinite else {
      return nil
    }
    return percent ? number / 100 : number
  }
}
