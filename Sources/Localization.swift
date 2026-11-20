import Foundation

enum AppLanguage: String, CaseIterable {
  case simplifiedChinese = "zh-Hans"
  case english = "en"

  private static let preference = "editor.ui.language"
  static var current: Self {
    UserDefaults.standard.string(forKey: preference).flatMap(Self.init(rawValue:))
      ?? .simplifiedChinese
  }
  static var appName: String { current == .english ? "MaoMiJian" : "毛咪剪" }

  var menuTitle: String {
    switch self {
    case .simplifiedChinese: return "简体中文"
    case .english: return "English"
    }
  }

  func select() { UserDefaults.standard.set(rawValue, forKey: Self.preference) }
}

struct LocalizedCopy: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
  let key: String
  let arguments: [String]

  init(stringLiteral value: String) {
    key = value
    arguments = []
  }

  init(stringInterpolation: StringInterpolation) {
    key = stringInterpolation.key
    arguments = stringInterpolation.arguments
  }

  struct StringInterpolation: StringInterpolationProtocol {
    var key = ""
    var arguments: [String] = []

    init(literalCapacity: Int, interpolationCount: Int) {
      key.reserveCapacity(literalCapacity)
      arguments.reserveCapacity(interpolationCount)
    }

    mutating func appendLiteral(_ literal: String) { key += literal }
    mutating func appendInterpolation<T>(_ value: T) {
      key += "{\(arguments.count)}"
      arguments.append(String(describing: value))
    }
  }
}

private enum EnglishCopy {
  static let bundle = Bundle.main.url(forResource: "en", withExtension: "lproj")
    .flatMap(Bundle.init(url:))
  static let argument = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
}

func LKey(_ key: String) -> String {
  guard AppLanguage.current == .english else { return key }
  return EnglishCopy.bundle?.localizedString(forKey: key, value: key, table: nil) ?? key
}

func L(_ copy: LocalizedCopy) -> String {
  let template = LKey(copy.key)
  guard !copy.arguments.isEmpty else { return template }
  var result = template
  for match in EnglishCopy.argument.matches(
    in: template, range: NSRange(template.startIndex..., in: template)
  ).reversed() {
    guard let token = Range(match.range, in: result),
      let capture = Range(match.range(at: 1), in: result),
      let index = Int(result[capture]), copy.arguments.indices.contains(index)
    else { continue }
    result.replaceSubrange(token, with: copy.arguments[index])
  }
  return result
}
