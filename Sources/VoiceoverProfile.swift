import Foundation

struct VoiceoverProfile: Codable, Identifiable, Equatable {
  var id = UUID()
  let name: String
  let referenceText: String

  private enum CodingKeys: String, CodingKey {
    case id, name
    case referenceText = "reference_text"
  }

  func folder(in support: URL) -> URL {
    Self.root(in: support).appendingPathComponent(id.uuidString, isDirectory: true)
  }

  private static func root(in support: URL) -> URL {
    support.appendingPathComponent("VoiceProfiles", isDirectory: true)
  }

  static func load(in support: URL) -> [Self] {
    let folders = (try? FileManager.default.contentsOfDirectory(
      at: root(in: support), includingPropertiesForKeys: nil)) ?? []
    return folders.compactMap { folder -> Self? in
      guard let id = UUID(uuidString: folder.lastPathComponent),
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("codes.npy").path),
        let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
        let profile = try? JSONDecoder().decode(Self.self, from: data), profile.id == id
      else { return nil }
      return profile
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
}
