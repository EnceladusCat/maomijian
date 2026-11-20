import Darwin
import Foundation

@main
struct MediaScratchChecks {
  static func main() throws {
    let fm = FileManager.default
    let args = CommandLine.arguments
    if args.count == 4 && args[1] == "--simulate-crash" {
      let scratch = MediaScratch(root: URL(fileURLWithPath: args[2], isDirectory: true))
      let local = try scratch.make(.audio)
      let external = try scratch.make(.video, beside: URL(fileURLWithPath: args[3], isDirectory: true))
      try Data(repeating: 8, count: 8192).write(to: local.url)
      try Data(repeating: 9, count: 4096).write(to: external.url)
      withExtendedLifetime((local, external)) { _exit(77) }
    }

    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let root = base.appendingPathComponent("managed", isDirectory: true)
    let output = base.appendingPathComponent("destination", isDirectory: true)
    let disconnected = base.appendingPathComponent("disconnected", isDirectory: true)
    try fm.createDirectory(at: output, withIntermediateDirectories: false)
    let finished = output.appendingPathComponent("成片.mp4")
    let original = base.appendingPathComponent("原素材.caf")
    try Data([1, 2]).write(to: finished)
    try Data([3, 4]).write(to: original)

    let owner = MediaScratch(root: root)
    let maintenance = MediaScratch(root: root)
    var local: MediaScratch.File? = try owner.make(.pitch)
    let localURL = local!.url
    try Data(repeating: 5, count: 1024).write(to: localURL)
    var staged: MediaScratch.File? = try owner.make(.video, beside: output)
    let stagedURL = staged!.url
    try Data(repeating: 6, count: 2048).write(to: stagedURL)
    try owner.cleanAbandoned()
    try maintenance.cleanAbandoned()
    let active = try maintenance.bytesInUse()
    precondition(active == 3072)
    precondition(fm.fileExists(atPath: localURL.path) && fm.fileExists(atPath: stagedURL.path))
    staged = nil
    precondition(!fm.fileExists(atPath: stagedURL.path))

    var interrupted: MediaScratch.File? = try owner.make(.audio, beside: output)
    let interruptedURL = interrupted!.url
    try Data([7]).write(to: interruptedURL)
    try fm.moveItem(at: output, to: disconnected)
    interrupted = nil
    try fm.moveItem(at: disconnected, to: output)
    try owner.cleanAbandoned()
    precondition(!fm.fileExists(atPath: interruptedURL.path))

    let child = Process()
    child.executableURL = URL(fileURLWithPath: args[0])
    child.arguments = ["--simulate-crash", root.path, output.path]
    try child.run()
    child.waitUntilExit()
    precondition(child.terminationStatus == 77)
    let afterCrash = try maintenance.bytesInUse()
    precondition(afterCrash == 13_312)
    try fm.moveItem(at: output, to: disconnected)
    try maintenance.cleanAbandoned()
    let afterDisconnect = try maintenance.bytesInUse()
    precondition(afterDisconnect == 1024)
    try fm.moveItem(at: disconnected, to: output)
    let afterReconnect = try maintenance.bytesInUse()
    precondition(afterReconnect == 5120)
    try maintenance.cleanAbandoned()
    let afterRetry = try maintenance.bytesInUse()
    precondition(afterRetry == 1024)

    let originalBytes = try Data(contentsOf: original)
    let finishedBytes = try Data(contentsOf: finished)
    precondition(originalBytes == Data([3, 4]) && finishedBytes == Data([1, 2]))
    local = nil
    precondition(!fm.fileExists(atPath: localURL.path))
    owner.close()
    let afterClose = try maintenance.bytesInUse()
    precondition(afterClose == 0)
    print("Passed active leases, external outputs, crash cleanup, disconnected-volume retry and normal exit.")
  }
}
