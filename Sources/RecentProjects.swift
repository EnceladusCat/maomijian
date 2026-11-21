import Combine
import Foundation

final class RecentProjects: ObservableObject {
  @Published private(set) var urls: [URL]
  private let defaults: UserDefaults
  private static let key = "editor.recentProjects.v1"
  private static let limit = 12

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    urls = (defaults.stringArray(forKey: Self.key) ?? []).prefix(Self.limit).map {
      URL(fileURLWithPath: $0)
    }
  }

  func record(_ url: URL) {
    let url = url.standardizedFileURL
    store(Array(([url] + urls.filter { $0 != url }).prefix(Self.limit)))
  }

  func title(for url: URL) -> String {
    let name = url.deletingPathExtension().lastPathComponent
    guard urls.filter({ $0.deletingPathExtension().lastPathComponent == name }).count > 1 else {
      return name
    }
    let parent = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    return "\(name) (\(parent))"
  }

  func clear() { store([]) }

  private func store(_ next: [URL]) {
    guard next != urls else { return }
    defaults.set(next.map(\.path), forKey: Self.key)
    urls = next
  }
}
