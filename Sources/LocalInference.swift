import Foundation

enum LocalInference {
  static func run(
    _ executable: URL, arguments: [String], scratch: MediaScratch, label: String = "Audio8",
    poll: () async -> Void = {}
  ) async throws -> Int32 {
    let log = try scratch.make(.log)
    try Data().write(to: log.url)
    let diagnostics = try FileHandle(forWritingTo: log.url)
    defer { try? diagnostics.close() }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = diagnostics
    process.qualityOfService = .utility

    try Task.checkCancellation()
    try process.run()
    defer {
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
    }
    while process.isRunning {
      try await Task.sleep(for: .milliseconds(250))
      await poll()
    }
    try Task.checkCancellation()
    if process.terminationStatus != 0, let details = try? String(contentsOf: log.url, encoding: .utf8) {
      NSLog("%@: %@", label, String(details.suffix(2000)))
    }
    return process.terminationStatus
  }
}
