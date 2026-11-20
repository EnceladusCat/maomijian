import Darwin
import Foundation

/// Work files are owned by a process session. Its advisory lock stays open
/// while any preview or job can use those files, and the OS unlocks it on exit.
final class MediaScratch {
  enum Format: String {
    case video = "mp4", audio = "m4a", pitch = "caf", subtitles = "srt"
  }

  final class File {
    let url: URL
    private let released: () -> Void

    fileprivate init(url: URL, released: @escaping () -> Void) {
      self.url = url
      self.released = released
    }
    deinit { released() }
  }

  static let shared = MediaScratch()
  private let root: URL
  private let files = FileManager.default
  private let mutex = NSLock()
  private var session: (folder: URL, lock: Int32)?
  private var active = Set<String>()
  private var closed = false
  private static let gate = ".maintenance"
  private static let owner = ".owner"
  private static let exportPrefix = ".maomijian-export-"

  init(root: URL? = nil) {
    self.root = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.framecut.editor")
      .appendingPathComponent("MediaScratch")
  }

  deinit { if let session { Darwin.close(session.lock) } }

  func make(_ format: Format, beside destination: URL? = nil) throws -> File {
    try withMaintenanceLock {
      guard !closed else { throw CocoaError(.userCancelled) }
      if session == nil {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
          let descriptor = try lock(folder.appendingPathComponent(Self.owner), create: true, wait: true)
          session = (folder, descriptor)
        } catch {
          try? files.removeItem(at: folder)
          throw error
        }
      }
      guard let folder = session?.folder else { throw POSIXError(.EIO) }
      let name = UUID().uuidString + "." + format.rawValue
      let destination = destination?.resolvingSymlinksInPath().standardizedFileURL
      if let destination, destination.path != folder.path {
        let receipt = folder.appendingPathComponent(name).appendingPathExtension("export")
        // Keep the final rename on the destination volume and leave a receipt
        // so a subsequent launch can find this exact staging file after a crash.
        try Data(destination.path.utf8).write(to: receipt, options: .atomic)
        let url = destination.appendingPathComponent(Self.exportPrefix + name)
        active.insert(receipt.lastPathComponent)
        return File(url: url) { [self] in
          mutex.withLock {
            if removeExportFile(url) { _ = removeRegularFile(receipt) }
            active.remove(receipt.lastPathComponent)
          }
        }
      }
      let url = folder.appendingPathComponent(name)
      active.insert(name)
      return File(url: url) { [self] in
        mutex.withLock {
          _ = removeRegularFile(url)
          active.remove(name)
        }
      }
    }
  }

  func cleanAbandoned() throws {
    guard files.fileExists(atPath: root.path) else { return }
    try withMaintenanceLock {
      for folder in try sessions() {
        if folder.lastPathComponent == session?.folder.lastPathComponent {
          clean(folder, keeping: active, keepDirectory: true)
          continue
        }
        let owner = folder.appendingPathComponent(Self.owner)
        // A process still holding its lock may be encoding or playing a file.
        guard let descriptor = try? lock(owner, create: false, wait: false) else { continue }
        defer { Darwin.close(descriptor) }
        clean(folder)
      }
    }
  }

  func bytesInUse() throws -> Int64 {
    guard files.fileExists(atPath: root.path) else { return 0 }
    return try withMaintenanceLock {
      var bytes: Int64 = 0
      for folder in try sessions() {
        for entry in try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
          if let export = externalFile(for: entry) { bytes += fileSize(export) }
          else if Self.workFileName(entry.lastPathComponent) { bytes += fileSize(entry) }
        }
      }
      return bytes
    }
  }

  func close() {
    mutex.withLock { closed = true }
    guard files.fileExists(atPath: root.path) else { return }
    try? withMaintenanceLock {
      guard let session else { return }
      clean(session.folder)
      Darwin.close(session.lock)
      self.session = nil
    }
  }

  private func clean(_ folder: URL, keeping active: Set<String> = [], keepDirectory: Bool = false) {
    guard let contents = try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    else { return }
    for entry in contents where !active.contains(entry.lastPathComponent) {
      if let export = externalFile(for: entry) {
        // Retain the receipt when an external volume is disconnected.
        if removeExportFile(export) { _ = removeRegularFile(entry) }
      } else if Self.workFileName(entry.lastPathComponent) {
        _ = removeRegularFile(entry)
      }
    }
    if !keepDirectory, (try? files.contentsOfDirectory(atPath: folder.path)) == [Self.owner] {
      try? files.removeItem(at: folder)
    }
  }

  private func externalFile(for receipt: URL) -> URL? {
    guard receipt.pathExtension == "export", isRegularFile(receipt) == true else { return nil }
    let name = receipt.deletingPathExtension().lastPathComponent
    guard Self.workFileName(name), fileSize(receipt) <= Int64(PATH_MAX),
      let path = try? String(contentsOf: receipt, encoding: .utf8), path.hasPrefix("/")
    else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
      .appendingPathComponent(Self.exportPrefix + name)
  }

  private static func workFileName(_ name: String) -> Bool {
    let fields = name.split(separator: ".", omittingEmptySubsequences: false)
    return fields.count == 2 && UUID(uuidString: String(fields[0])) != nil
      && Format(rawValue: String(fields[1])) != nil
  }

  private func sessions() throws -> [URL] {
    try files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      .filter {
        guard UUID(uuidString: $0.lastPathComponent) != nil,
          let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
      }
  }

  private func isRegularFile(_ url: URL) -> Bool? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return errno == ENOENT ? nil : false }
    return info.st_mode & S_IFMT == S_IFREG
  }

  private func fileSize(_ url: URL) -> Int64 {
    guard isRegularFile(url) == true else { return 0 }
    return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
  }

  private func removeRegularFile(_ url: URL) -> Bool {
    guard let regular = isRegularFile(url) else { return true }
    guard regular else { return false }
    do {
      try files.removeItem(at: url)
      return true
    } catch {
      return isRegularFile(url) == nil
    }
  }

  private func removeExportFile(_ url: URL) -> Bool {
    let parent = url.deletingLastPathComponent()
    guard parent.resolvingSymlinksInPath().path == parent.path,
      (try? parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    else { return false }
    return removeRegularFile(url)
  }

  private func withMaintenanceLock<T>(_ work: () throws -> T) throws -> T {
    try mutex.withLock {
      try files.createDirectory(at: root, withIntermediateDirectories: true)
      let descriptor = try lock(root.appendingPathComponent(Self.gate), create: true, wait: true)
      defer { Darwin.close(descriptor) }
      return try work()
    }
  }

  private func lock(_ url: URL, create: Bool, wait: Bool) throws -> Int32 {
    let flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW | (create ? O_CREAT : 0)
    let fd = Darwin.open(url.path, flags, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    while flock(fd, LOCK_EX | (wait ? 0 : LOCK_NB)) != 0 {
      let failure = errno
      if failure == EINTR { continue }
      Darwin.close(fd)
      throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
    }
    return fd
  }
}
