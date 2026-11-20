import AVFoundation
import AudioToolbox

/// A PCM copy at a transposed sample rate. AVFoundation stretches that copy to
/// the authored timeline duration with its pitch-preserving spectral algorithm.
final class PitchedAudio {
  private let storage: MediaScratch.File
  let readable: AVURLAsset
  private init(storage: MediaScratch.File) {
    self.storage = storage
    readable = AVURLAsset(url: storage.url)
  }
  static let cacheLimit: Int64 = 160 * 1024 * 1024
  private static let cacheLock = NSLock()
  private static var cache = [String: (audio: PitchedAudio, size: Int64, use: UInt64)]()
  private static var cacheBytes: Int64 = 0
  private static var usage: UInt64 = 0

  static func clearCache() {
    cacheLock.withLock {
      cache.removeAll()
      cacheBytes = 0
    }
  }

  private static func hit(_ key: String) -> PitchedAudio? {
    cacheLock.withLock {
      guard var found = cache[key] else { return nil }
      usage += 1
      found.use = usage
      cache[key] = found
      return found.audio
    }
  }

  private static func remember(_ audio: PitchedAudio, as key: String, size: Int64) -> PitchedAudio {
    guard size <= cacheLimit else { return audio }
    return cacheLock.withLock {
      if let previous = cache[key]?.audio { return previous }
      while cacheBytes + size > cacheLimit, let oldest = cache.min(by: { $0.value.use < $1.value.use }) {
        cacheBytes -= oldest.value.size
        cache.removeValue(forKey: oldest.key)
      }
      usage += 1
      cache[key] = (audio, size, usage)
      cacheBytes += size
      return audio
    }
  }
  static func make(
    _ asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange, semitones: Double,
    cancelled: () -> Bool
  ) throws -> PitchedAudio {
    let props = try asset.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let key =
      "\(asset.url.standardizedFileURL.path)|\(props.fileSize ?? 0)|\(props.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(track.trackID)|\(range.start.seconds.bitPattern)|\(range.duration.seconds.bitPattern)|\(semitones.bitPattern)"
    if let cached = hit(key) { return cached }
    let storage = try MediaScratch.shared.make(.pitch)
    defer { withExtendedLifetime(storage) {} }
    let destination = storage.url
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = range
    guard let description = track.formatDescriptions.first,
      let original = CMAudioFormatDescriptionGetStreamBasicDescription(
        description as! CMFormatDescription)?.pointee
    else {
      throw EditError.message(L("无法读取音频格式。"))
    }
    let rawPCM =
      original.mFormatID == kAudioFormatLinearPCM && original.mBytesPerFrame > 0
      && (original.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
    let settings: [String: Any] = [
      AVSampleRateKey: original.mSampleRate, AVNumberOfChannelsKey: Int(original.mChannelsPerFrame),
      AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: rawPCM ? nil : settings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw EditError.message(L("无法读取变调音频。")) }
    reader.add(output)
    guard reader.startReading() else {
      throw EditError.message(L("无法启动音频解码。") + (reader.error?.localizedDescription ?? ""))
    }
    var file: AudioFileID?
    var position: Int64 = 0
    defer { if let file { AudioFileClose(file) } }
    while let sample = output.copyNextSampleBuffer() {
      if cancelled() {
        reader.cancelReading()
        throw EditError.message(L("音频处理已取消。"))
      }
      guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
      try autoreleasepool {
        guard let desc = CMSampleBufferGetFormatDescription(sample),
          var format = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
          let block = CMSampleBufferGetDataBuffer(sample), format.mBytesPerFrame > 0
        else { throw EditError.message(L("不支持该音频格式。")) }
        let hz = format.mSampleRate
        if file == nil {
          format.mSampleRate *= pow(2, semitones / 12)
          guard
            AudioFileCreateWithURL(
              destination as CFURL, kAudioFileCAFType, &format, .eraseFile, &file) == noErr
          else { throw EditError.message(L("无法创建变调音频缓存。")) }
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let bpf = Int(format.mBytesPerFrame)
        let sampleCount = CMBlockBufferGetDataLength(block) / bpf
        let offset = bound(Int(((range.start.seconds - pts) * hz).rounded()), 0, sampleCount)
        let end = bound(Int(((range.end.seconds - pts) * hz).rounded()), offset, sampleCount)
        let byteCount = (end - offset) * bpf
        guard byteCount > 0, let file else { return }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard
          CMBlockBufferCopyDataBytes(
            block, atOffset: offset * bpf, dataLength: byteCount, destination: &bytes) == noErr
        else { throw EditError.message(L("读取音频样本失败。")) }
        var count = UInt32(byteCount)
        guard AudioFileWriteBytes(file, false, position, &count, bytes) == noErr,
          Int(count) == byteCount
        else { throw EditError.message(L("写入变调音频失败。")) }
        position += Int64(count)
      }
    }
    guard reader.status == .completed, position > 0 else {
      throw EditError.message(L("未能解码所选范围的音频样本。") + (reader.error?.localizedDescription ?? ""))
    }
    if let outputFile = file {
      AudioFileClose(outputFile)
      file = nil
    }
    let result = PitchedAudio(storage: storage)
    let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
    return size.map { remember(result, as: key, size: Int64($0)) } ?? result
  }
}
