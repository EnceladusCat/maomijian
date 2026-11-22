import CryptoKit
import Darwin
import Foundation

struct Audio8Model {
  private struct File: Decodable {
    let path: String
    let size: Int
    let sha256: String
  }

  let revision: String
  private let files: [File]

  private struct Manifest: Decodable {
    let revision: String
    let files: [File]
  }

  init(resources: URL) throws {
    let data = try Data(contentsOf: resources.appendingPathComponent("model.json"))
    let manifest = try JSONDecoder().decode(Manifest.self, from: data)
    revision = manifest.revision
    files = manifest.files
  }

  func prepare(
    in root: URL, registration: Bool = false, progress: (Double) async -> Void
  ) async throws -> URL {
    let needed = files.filter { $0.path.hasPrefix("registration/") == registration }
    let bytes = needed.reduce(0) { $0 + $1.size }
    let folder = root.appendingPathComponent(revision, isDirectory: true)
    let fm = FileManager.default
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let lock = open(folder.appendingPathComponent(".download-lock").path, O_CREAT | O_RDWR, 0o600)
    guard lock >= 0 else { throw POSIXError(.EIO) }
    defer { close(lock) }
    while flock(lock, LOCK_EX | LOCK_NB) != 0 {
      guard errno == EWOULDBLOCK || errno == EINTR else { throw POSIXError(.EIO) }
      try await Task.sleep(for: .milliseconds(300))
    }
    defer { flock(lock, LOCK_UN) }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 45
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var completed = 0
    for file in needed {
      try Task.checkCancellation()
      let destination = folder.appendingPathComponent(file.path)
      if Self.size(destination) != file.size {
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await download(file, to: destination, session: session) { offset in
          await progress(Double(completed + offset) / Double(bytes))
        }
      }
      completed += file.size
    }
    return folder
  }

  private func download(
    _ file: File, to target: URL, session: URLSession, progress: (Int) async -> Void
  ) async throws {
    let partial = target.appendingPathExtension("partial")
    let fm = FileManager.default
    if !fm.fileExists(atPath: partial.path) { try Data().write(to: partial) }
    let output = try FileHandle(forWritingTo: partial)
    defer { try? output.close() }
    var offset = Self.size(partial) ?? 0
    if offset > file.size {
      try output.truncate(atOffset: 0)
      offset = 0
    }
    try output.seek(toOffset: UInt64(offset))
    let url = URL(string: "https://huggingface.co/Edge0/audio8-TTS-0.1B-ONNX-INT8/resolve/\(revision)/\(file.path)?download=true")!
    let chunkSize = 8 * 1024 * 1024
    while offset < file.size {
      try Task.checkCancellation()
      let end = min(offset + chunkSize, file.size) - 1
      var request = URLRequest(url: url)
      let ranged = offset > 0 || file.size > chunkSize
      if ranged { request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range") }
      let data = try await downloadChunk(request, session: session, expected: end - offset + 1,
                                         range: ranged ? "bytes \(offset)-\(end)/\(file.size)" : nil)
      try output.write(contentsOf: data)
      offset = end + 1
      await progress(offset)
    }
    try output.close()
    guard try Self.checksum(partial) == file.sha256 else {
      try fm.removeItem(at: partial)
      throw EditError.message(L("配音模型校验失败，请重试。"))
    }
    if fm.fileExists(atPath: target.path) {
      _ = try fm.replaceItemAt(target, withItemAt: partial)
    } else {
      try fm.moveItem(at: partial, to: target)
    }
  }

  private func downloadChunk(
    _ request: URLRequest, session: URLSession, expected: Int, range: String?
  ) async throws -> Data {
    for attempt in 0...2 {
      do {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count == expected,
          http.statusCode == (range == nil ? 200 : 206),
          range == nil || http.value(forHTTPHeaderField: "Content-Range") == range
        else { throw URLError(.badServerResponse) }
        return data
      } catch {
        try Task.checkCancellation()
        if attempt == 2 { throw error }
        try await Task.sleep(for: .seconds(attempt + 1))
      }
    }
    throw URLError(.cannotLoadFromNetwork)
  }

  private static func size(_ url: URL) -> Int? {
    try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
  }

  private static func checksum(_ url: URL) throws -> String {
    let input = try FileHandle(forReadingFrom: url)
    defer { try? input.close() }
    var digest = SHA256()
    while let data = try input.read(upToCount: 1 << 20), !data.isEmpty {
      try Task.checkCancellation()
      digest.update(data: data)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
