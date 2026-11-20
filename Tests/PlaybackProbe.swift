import AVFoundation
import AppKit
import QuartzCore

enum RenderStatistics {
  private static let lock = NSLock()
  private static var frames: [Int: Double] = [:]
  private static var directFrames = Set<Int>()
  private static var parityChecks = [Int: Bool]()
  static func record(_ frame: Int, _ milliseconds: Double, direct: Bool = false) {
    lock.lock()
    frames[frame] = max(frames[frame] ?? 0, milliseconds)
    if direct { directFrames.insert(frame) }
    lock.unlock()
  }
  static func recordParity(_ frame: Int, matches: Bool) {
    lock.withLock { parityChecks[frame] = (parityChecks[frame] ?? true) && matches }
  }
  static func parity() -> [String: Any] {
    lock.withLock {
      ["framesChecked": parityChecks.count, "mismatch": parityChecks.filter { !$0.value }.keys.sorted()]
    }
  }
  static func summary(_ first: Int, _ last: Int) -> [String: Any] {
    lock.lock()
    defer { lock.unlock() }
    let values = frames.filter { first...last ~= $0.key }.values.sorted()
    guard !values.isEmpty else { return [:] }
    return [
      "uniqueComposedFrames": values.count, "notComposed": last - first + 1 - values.count,
      "p95ComposeMs": values[Int(Double(values.count - 1) * 0.95)], "maxComposeMs": values.last!,
      "directFrames": directFrames.filter { first...last ~= $0 }.count,
    ]
  }
}
// Test-only entry, compiled into a separate application together with the shipping editor and window.
struct ProbeConfig: Decodable {
  var project: String, result: String, runSeconds: Double
  var example: String?, movie: String?
}
final class PlaybackProbe {
  static var running: PlaybackProbe?
  static func launch(_ editor: Editor) {
    let u = Bundle.main.url(forResource: "Probe", withExtension: "json")!
    let config = try! JSONDecoder().decode(ProbeConfig.self, from: Data(contentsOf: u))
    running = PlaybackProbe(editor, config)
    running?.start()
  }
  let e: Editor, cfg: ProbeConfig
  let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
  ])
  var timer: Timer?, phase = "load", began = 0.0, opened = 0.0, firstFrameWall = 0.0,
    lastFrameWall = 0.0
  var lastFrame = -1, firstFrame = -1, observed = 0, missed = 0, gaps = [Double](),
    tickGaps = [Double](), lastTick = 0.0
  var results = [String: Any](), drags = [[String: Any]](), gesture = 0, lastStep = -1,
    released = 0.0, target = 0, dragOutputs = 0, lastDragFrame = -1, firstDragWall = 0.0
  private var nextCheckpoint = 0.0
  private var checkpoints = [[String: Any]]()
  private var activity: NSObjectProtocol?
  private weak var testWindow: NSWindow?
  private var inputMonitor: Any?
  let paths = [
    (0.10, 0.115), (0.72, 0.18), (0.54, 0.56), (0.03, 0.87), (0.87, 0.84), (0.94, 0.23),
    (0.32, 0.34), (0.16, 0.75), (0.40, 0.38), (0.87, 0.09), (0.61, 0.63), (0.15, 0.90),
  ]
  init(_ e: Editor, _ config: ProbeConfig) {
    self.e = e
    cfg = config
  }
  func start() {
    // Do not let ordinary mouse/keyboard input alter a timed, scripted transport run.
    testWindow = NSApp.windows.first { $0.contentView != nil && $0.canBecomeMain }
    testWindow?.title = "毛咪剪 · 长录屏自动测试"
    testWindow?.ignoresMouseEvents = true
    inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [
      .keyDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel,
    ]) { _ in nil }
    activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .latencyCritical], reason: "Measuring interactive video playback")
    opened = CACurrentMediaTime()
    e.player.isMuted = true
    e.open(URL(fileURLWithPath: cfg.project))
    let t = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] _ in self?.tick() }
    timer = t
    RunLoop.main.add(t, forMode: .common)
    results["previewShortSide"] = e.preview
    save("loading")
  }
  func save(_ status: String) {
    var data = results
    data["stage"] = status
    data["drags"] = drags
    data["pixelParity"] = RenderStatistics.parity()
    try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(
      to: URL(fileURLWithPath: cfg.result), options: .atomic)
  }
  func sample(_ now: Double) -> Int? {
    let time = output.itemTime(forHostTime: now)
    guard time.isNumeric, output.hasNewPixelBuffer(forItemTime: time) else { return nil }
    var shown = CMTime.invalid
    guard output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &shown) != nil,
      shown.isNumeric
    else { return nil }
    return Int((shown.seconds * 30).rounded())
  }
  func tick() {
    let now = CACurrentMediaTime()
    if let err = e.error {
      stop("error " + err)
      return
    }
    switch phase {
    case "load":
      guard let item = e.player.currentItem, item.status == .readyToPlay else {
        if now - opened > 35 { stop("item readiness timeout") }
        return
      }
      item.add(output)
      e.seek(30 * 16)
      began = now
      phase = "warm"
      results["loadSeconds"] = now - opened
    case "warm":
      _ = sample(now)
      if now - began > 1.2 {
        e.play()
        began = now
        phase = "play"
        save("playing")
      }
    case "play":
      if now >= nextCheckpoint {
        let item = e.player.currentItem
        checkpoints.append([
          "wall": now - began, "seconds": e.player.currentTime().seconds,
          "outputFrame": lastFrame, "seen": observed, "rate": e.player.rate,
          "transportPlaying": e.transport.playing, "control": e.player.timeControlStatus.rawValue,
          "waiting": e.player.reasonForWaitingToPlay?.rawValue ?? "",
          "error": item?.error?.localizedDescription ?? "",
        ])
        results["checkpoints"] = checkpoints
        save("playing")
        nextCheckpoint = now + 5
      }
      if lastTick > 0 { tickGaps.append(1000 * (now - lastTick)) }
      lastTick = now
      if let f = sample(now), f >= 16 * 30 - 1, f > lastFrame {
        if firstFrame < 0 {
          firstFrame = f
          firstFrameWall = now
        } else {
          missed += max(0, f - lastFrame - 1)
          gaps.append(1000 * (now - lastFrameWall))
        }
        lastFrame = f
        lastFrameWall = now
        observed += 1
      }
      if firstFrame >= 0 && lastFrame - firstFrame >= Int(cfg.runSeconds * 30) {
        results["play"] = [
          "mediaSeconds": Double(lastFrame - firstFrame) / 30,
          "wallSeconds": lastFrameWall - firstFrameWall, "uniqueFrames": observed,
          "skippedFrameNumbers": missed, "maxFrameGapMs": gaps.max() ?? 0,
          "p95FrameGapMs": q(gaps, 0.95), "gapsOver100ms": gaps.filter { $0 >= 100 }.count,
          "p95PollGapMs": q(tickGaps, 0.95), "maxPollGapMs": tickGaps.max() ?? 0,
        ]
        results["compositor"] = RenderStatistics.summary(firstFrame, lastFrame)
        if let events = e.player.currentItem?.accessLog()?.events, !events.isEmpty {
          let drops = events.map(\.numberOfDroppedVideoFrames).filter { $0 >= 0 }
          if !drops.isEmpty { results["accessLogDrops"] = drops.reduce(0, +) }
        }
        e.pause()
        beginDrag(now)
      } else if now - began > cfg.runSeconds + 18 {
        results["partial"] = [
          "first": firstFrame, "last": lastFrame, "sampled": observed,
          "playerTime": e.player.currentTime().seconds,
        ]
        stop("playback timeout")
      }
    case "drag":
      if let f = sample(now), f != lastDragFrame {
        if dragOutputs == 0 { firstDragWall = now }
        dragOutputs += 1
        lastDragFrame = f
      }
      let step = min(48, Int((now - began) * 60))
      if step > lastStep {
        let path = paths[gesture]
        let fraction = Double(step) / 48
        target = Int((path.0 + (path.1 - path.0) * fraction) * Double(e.p.duration))
        if step == 48 {
          releaseTarget(target)
          released = now
          phase = "settle"
        } else {
          dragTarget(target)
        }
        lastStep = step
      }
    case "settle":
      if let f = sample(now) { lastDragFrame = f }
      if lastDragFrame == target || now - released > 3 {
        drags.append([
          "sweep": gesture, "target": target, "match": lastDragFrame == target,
          "settleMs": 1000 * (now - released), "updatesDuringDrag": dragOutputs,
          "firstUpdateMs": firstDragWall > 0 ? 1000 * (firstDragWall - began) : -1,
        ])
        gesture += 1
        if gesture == paths.count { stop("complete") } else { beginDrag(now) }
      }
    default: break
    }
  }
  func dragTarget(_ frame: Int) { e.scrub(frame) }
  func releaseTarget(_ frame: Int) { e.seek(frame) }
  func beginDrag(_ now: Double) {
    phase = "drag"
    began = now
    lastStep = -1
    firstDragWall = 0
    lastDragFrame = -1
    dragOutputs = 0
    save("scrubbing")
  }
  func q(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    return values.sorted()[Int(Double(values.count - 1) * fraction)]
  }
  func stop(_ message: String) {
    if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
    testWindow?.ignoresMouseEvents = false
    testWindow?.title = "毛咪剪 · 长录屏测试结束"
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    phase = "done"
    timer?.invalidate()
    e.pause()
    if let item = e.player.currentItem, item.outputs.contains(output) { item.remove(output) }
    save(message)
    if let input = cfg.example, let dest = cfg.movie {
      if !e.dirty { e.open(URL(fileURLWithPath: input)) }
      DispatchQueue.global().async {
        do {
          let project = try Project.read(from: URL(fileURLWithPath: input))
          try ExportJob().run(project, to: URL(fileURLWithPath: dest), short: 1080) { _ in }
        } catch {
          try? error.localizedDescription.write(
            toFile: dest + ".error", atomically: true, encoding: .utf8)
        }
      }
    }
  }
}
