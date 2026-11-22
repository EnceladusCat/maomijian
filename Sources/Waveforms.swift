import AVFoundation
import Combine

final class AudioWaveform: Equatable {
  let frames: Int
  let peaks: [UInt8]

  init(frames: Int, peaks: [UInt8]) {
    self.frames = frames
    self.peaks = peaks
  }

  static func == (lhs: AudioWaveform, rhs: AudioWaveform) -> Bool { lhs === rhs }

  static func cached(_ media: Media, cancelled: () -> Bool) -> (hasAudio: Bool, wave: AudioWaveform?) {
    WaveformCache.shared.read(media, cancelled: cancelled)
  }

  func peak(from start: Double, to end: Double) -> Double {
    guard !peaks.isEmpty, start < Double(frames), end > 0 else { return 0 }
    let rate = Double(peaks.count) / Double(frames)
    let first = bound(Int(floor(start * rate)), 0, peaks.count - 1)
    let last = bound(Int(ceil(end * rate)), first + 1, peaks.count)
    return Double(peaks[first..<last].max() ?? 0) / 255
  }

  static func read(_ media: Media, cancelled: () -> Bool) -> (hasAudio: Bool, wave: AudioWaveform?) {
    let asset = AVURLAsset(
      url: URL(fileURLWithPath: media.path),
      options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    guard !cancelled(), let track = asset.tracks(withMediaType: .audio).first else {
      return (false, nil)
    }
    guard let reader = try? AVAssetReader(asset: asset) else { return (true, nil) }
    let output = AVAssetReaderTrackOutput(
      track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { return (true, nil) }
    reader.add(output)
    guard reader.startReading() else { return (true, nil) }
    defer { if reader.status == .reading { reader.cancelReading() } }

    var peaks = [UInt8](repeating: 0, count: min(media.frames, 32_768))
    let binsPerSecond = Double(peaks.count) * Double(fps) / Double(media.frames)
    var samples = [Int16]()
    while !cancelled(), let sample = output.copyNextSampleBuffer() {
      autoreleasepool {
        guard let data = sample.dataBuffer, let description = sample.formatDescription,
          let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
          format.mSampleRate > 0, format.mChannelsPerFrame > 0
        else { return }
        let start = sample.presentationTimeStamp.seconds
        guard start.isFinite else { return }
        let channels = Int(format.mChannelsPerFrame)
        let bytes = CMBlockBufferGetDataLength(data)
        guard bytes.isMultiple(of: MemoryLayout<Int16>.size) else { return }
        let count = bytes / MemoryLayout<Int16>.size
        let frameCount = min(sample.numSamples, count / channels)
        guard frameCount > 0 else { return }
        readPCM(data, count: count, scratch: &samples) { pcm in
          let rate = format.mSampleRate
          var frame = Int(bound(ceil(-start * rate), 0, Double(frameCount)))
          let end = Int(bound(
            ceil((Double(media.frames) / Double(fps) - start) * rate), Double(frame), Double(frameCount)))
          let source = pcm.baseAddress!
          while frame < end {
            let index = bound(
              Int(floor((start + Double(frame) / rate) * binsPerSecond)), 0, peaks.count - 1)
            let next = bound(Int(ceil((Double(index + 1) / binsPerSecond - start) * rate)),
              frame + 1, end)
            var magnitude = 0
            for i in frame * channels..<next * channels {
              magnitude = max(magnitude, abs(Int(source[i])))
            }
            peaks[index] = max(peaks[index], UInt8((magnitude * 255 + 16_384) / 32_768))
            frame = next
          }
        }
      }
    }
    guard !cancelled(), reader.status == .completed else { return (true, nil) }
    return (true, AudioWaveform(frames: media.frames, peaks: peaks))
  }

  static func readPCM(
    _ data: CMBlockBuffer, count: Int, scratch: inout [Int16],
    consume: (UnsafeBufferPointer<Int16>) -> Void
  ) {
    let bytes = count * MemoryLayout<Int16>.stride
    var available = 0
    var contiguous: UnsafeMutablePointer<Int8>?
    let status = CMBlockBufferGetDataPointer(
      data, atOffset: 0, lengthAtOffsetOut: &available, totalLengthOut: nil,
      dataPointerOut: &contiguous)
    if status == noErr, bytes <= available, let contiguous,
      Int(bitPattern: contiguous).isMultiple(of: MemoryLayout<Int16>.alignment)
    {
      let pointer = UnsafeRawPointer(contiguous).assumingMemoryBound(to: Int16.self)
      withExtendedLifetime(data) { consume(UnsafeBufferPointer(start: pointer, count: count)) }
      return
    }
    if scratch.count < count { scratch = [Int16](repeating: 0, count: count) }
    let read = scratch.withUnsafeMutableBytes {
      CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!)
    }
    if read == noErr {
      scratch.withUnsafeBufferPointer {
        consume(UnsafeBufferPointer(start: $0.baseAddress, count: count))
      }
    }
  }
}

private final class WaveformCache {
  private final class Entry {
    let result: (hasAudio: Bool, wave: AudioWaveform?)
    init(_ result: (hasAudio: Bool, wave: AudioWaveform?)) { self.result = result }
  }
  static let shared = WaveformCache()
  private let condition = NSCondition()
  private let entries = NSCache<NSString, Entry>()
  private var inFlight = Set<String>()

  private init() {
    entries.totalCostLimit = 32 * 1024 * 1024
    entries.countLimit = 512
  }

  func read(_ media: Media, cancelled: () -> Bool) -> (hasAudio: Bool, wave: AudioWaveform?) {
    let url = URL(fileURLWithPath: media.path).standardizedFileURL
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    let time = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
    let key = "\(url.path)\n\(media.frames)\n\(values?.fileSize ?? 0)\n\(time)"
    condition.lock()
    while !cancelled() {
      if let entry = entries.object(forKey: key as NSString) {
        condition.unlock()
        return entry.result
      }
      if inFlight.insert(key).inserted {
        condition.unlock()
        let result = AudioWaveform.read(media, cancelled: cancelled)
        condition.lock()
        if values != nil, let wave = result.wave, !cancelled() {
          entries.setObject(Entry(result), forKey: key as NSString, cost: wave.peaks.count)
        }
        inFlight.remove(key)
        condition.broadcast()
        condition.unlock()
        return result
      }
      _ = condition.wait(until: Date(timeIntervalSinceNow: 0.1))
    }
    condition.unlock()
    return (false, nil)
  }
}

final class WaveformStore: ObservableObject {
  @Published private(set) var values = [UUID: AudioWaveform]()
  private var requested = [UUID: Media]()
  private var tasks = [UUID: Progress]()
  private let queue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "framecut.waveforms"
    queue.qualityOfService = .utility
    queue.maxConcurrentOperationCount = 1
    return queue
  }()

  func load(_ media: Media, refresh: Bool = false, detected: @escaping () -> Void) {
    guard !media.isStill, refresh || requested[media.id] != media else { return }
    requested[media.id] = media
    tasks[media.id]?.cancel()
    if values[media.id] != nil { values[media.id] = nil }
    let task = Progress(totalUnitCount: 0)
    tasks[media.id] = task
    queue.addOperation { [weak self] in
      guard !task.isCancelled else { return }
      let result = AudioWaveform.cached(media) { task.isCancelled }
      DispatchQueue.main.async {
        guard let self, self.tasks[media.id] === task else { return }
        self.tasks[media.id] = nil
        if self.values[media.id] != result.wave { self.values[media.id] = result.wave }
        if result.hasAudio { detected() }
      }
    }
  }

  func reset() {
    tasks.values.forEach { $0.cancel() }
    tasks.removeAll()
    requested.removeAll()
    values.removeAll()
  }
}
